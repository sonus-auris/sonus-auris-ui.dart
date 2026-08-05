#!/usr/bin/env python3
"""Executable contracts for complete, bounded iOS Simulator log evidence."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/device-lab/ios-simulator-smoke.sh"
REDUCER = ROOT / "scripts/device-lab/log-evidence.py"
EXPECTED_SUCCESS_PHASES = {
    "first-launch",
    "cold-relaunch",
    "post-update-relaunch",
}


def function_body(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^{re.escape(name)}\(\) \{{\n(?P<body>.*?)^\}}\n",
        source,
    )
    if not match:
        raise AssertionError(f"missing shell function: {name}")
    return match.group("body")


def compile_python_heredocs(source: str) -> None:
    blocks = re.findall(r"(?ms)<<'PY'[^\n]*\n(?P<body>.*?)^PY$", source)
    assert blocks, "no Python heredocs were found"
    for index, block in enumerate(blocks, start=1):
        compile(block, f"ios-simulator-smoke.sh:python-heredoc-{index}", "exec")


def validate_contract(source: str) -> None:
    assert "| tail -n 500" not in source
    assert 'LOG_EVIDENCE="$ROOT/scripts/device-lab/log-evidence.py"' in source
    assert 'LOG_MAX_BYTES="${SONUS_SIMULATOR_LOG_MAX_BYTES:-524288}"' in source
    assert '[[ ! "$LOG_MAX_BYTES" =~ ^[0-9]+$ ]]' in source
    compile_python_heredocs(source)

    sanitizer = function_body(source, "sanitize_stream")
    assert "for line in sys.stdin:" in sanitizer
    assert "sys.stdin.read()" not in sanitizer
    assert 'sys.stdin.reconfigure(errors="replace")' in sanitizer

    capture = function_body(source, "capture_logs")
    assert 'predicate="processIdentifier == $CURRENT_PID"' in capture
    assert 'local status_file="$EVIDENCE_DIR/$label-log-scan.json"' in capture
    assert 'python3 "$LOG_EVIDENCE"' in capture
    assert '--max-bytes "$LOG_MAX_BYTES"' in capture
    assert '--status-file "$status_file"' in capture
    assert "tail -n" not in capture

    fatal_assertion = function_body(source, "assert_no_fatal_logs")
    assert 'local status_file="$EVIDENCE_DIR/$label-log-scan.json"' in fatal_assertion
    assert 'payload.get("schema") != "sonus-auris-log-evidence/v1"' in fatal_assertion
    assert 'payload.get("full_stream_scanned") is not True' in fatal_assertion
    assert 'payload.get("fatal_observed") is True' in fatal_assertion
    assert "grep -Eq" in fatal_assertion

    capture_phases = set(
        re.findall(r"(?m)^capture_logs (first-launch|cold-relaunch|post-update-relaunch)$", source)
    )
    assert capture_phases == EXPECTED_SUCCESS_PHASES, capture_phases
    assertion_phases = set(
        re.findall(
            r"(?m)^assert_no_fatal_logs (first-launch|cold-relaunch|post-update-relaunch)$",
            source,
        )
    )
    assert assertion_phases == EXPECTED_SUCCESS_PHASES, assertion_phases
    assert 'capture_logs "$label-launch-failure"' in source

    for marker in (
        "process_scoped_logs=true",
        "startup_log_context_preserved=true",
        "full_log_fatal_scan=true",
        "log_status_sidecars=true",
        "simulator_log_max_bytes=$LOG_MAX_BYTES",
    ):
        assert marker in source, marker

    # Preserve the simulator's app and data. These patterns match executable
    # command positions rather than explanatory prose.
    forbidden = (
        r"(?m)^\s*xcrun\s+simctl\s+erase(?:\s|$)",
        r"(?m)^\s*xcrun\s+simctl\s+uninstall(?:\s|$)",
        r"(?m)^\s*rm\s+-rf(?:\s|$)",
    )
    for pattern in forbidden:
        assert re.search(pattern, source) is None, pattern


def run_reducer(payload: bytes, maximum: int) -> tuple[bytes, dict[str, object]]:
    with tempfile.TemporaryDirectory() as directory:
        status_path = Path(directory) / "status.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(REDUCER),
                "--max-bytes",
                str(maximum),
                "--status-file",
                str(status_path),
            ],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        status = json.loads(status_path.read_text(encoding="utf-8"))
        return completed.stdout, status


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
    subprocess.run([sys.executable, "-m", "py_compile", str(REDUCER)], check=True)
    subprocess.run([sys.executable, str(REDUCER), "--self-test"], check=True)
    validate_contract(source)

    hidden_fatal = (
        b"startup-context\n"
        + b"before\n" * 5000
        + b"EXC_CRASH hidden outside retained windows\n"
        + b"after\n" * 5000
        + b"terminal-context\n"
    )
    output, status = run_reducer(hidden_fatal, 2048)
    assert len(output) <= 2048
    assert output.startswith(b"startup-context\n")
    assert output.endswith(b"terminal-context\n")
    assert b"EXC_CRASH" not in output
    assert status["fatal_observed"] is True
    assert status["fatal_patterns"] == ["exc-crash"]
    assert status["full_stream_scanned"] is True
    assert status["raw_log_embedded_in_status"] is False
    assert status["original_bytes"] == len(hidden_fatal)

    clean_output, clean_status = run_reducer(
        b"BOOT\n" + b"normal event\n" * 1000 + b"READY\n",
        2048,
    )
    assert len(clean_output) <= 2048
    assert clean_status["fatal_observed"] is False
    assert clean_status["fatal_patterns"] == []

    # Mutation checks prove the contract fails when future edits restore the
    # original lossy tail or remove the sidecar/full-stream evidence markers.
    mutations = (
        source.replace("  } \\\n    | sanitize_stream", "  } \\\n    | tail -n 500 \\\n    | sanitize_stream", 1),
        source.replace('--status-file "$status_file"', "", 1),
        source.replace("full_log_fatal_scan=true", "full_log_fatal_scan=false", 1),
        source.replace("from pathlib import Path", "from pathlib import import Path", 1),
    )
    for mutated in mutations:
        try:
            validate_contract(mutated)
        except (AssertionError, SyntaxError):
            pass
        else:
            raise AssertionError("contract mutation unexpectedly passed")

    print(
        "iOS Simulator log evidence contract passed: full-stream fatal scan + "
        "bounded startup/tail retention + sidecars + Python heredocs + 4 mutation refusals"
    )


if __name__ == "__main__":
    main()
