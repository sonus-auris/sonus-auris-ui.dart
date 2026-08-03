#!/usr/bin/env python3
"""Contracts for complete, bounded iOS Simulator log evidence."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "scripts/device-lab/ios-simulator-full-log-smoke.sh"
REDUCER = ROOT / "scripts/device-lab/bounded-log-scan.py"
WORKFLOW = ROOT / ".github/workflows/device-lab.yml"


def main() -> None:
    source = WRAPPER.read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")

    subprocess.run(["bash", "-n", str(WRAPPER)], check=True)
    subprocess.run([sys.executable, "-m", "py_compile", str(REDUCER)], check=True)
    subprocess.run([sys.executable, str(REDUCER), "--self-test"], check=True)

    assert 'bash "$ROOT/scripts/device-lab/ios-simulator-smoke.sh" "$UDID"' in source
    assert '--start "$LOG_START"' in source
    assert 'evidence-policy.py" --stream' in source
    assert 'bounded-log-scan.py"' in source
    assert '--report "$LOG_REPORT"' in source
    assert "tail -n 500" not in source
    assert "full_log_stream_scanned=true" in source
    assert "startup_log_context_preserved=true" in source
    assert "terminal_log_context_preserved=true" in source
    assert "retained_log_max_bytes=$MAX_LOG_BYTES" in source

    required_scan_names = {
        "uncaught",
        "fatal",
        "exception",
        "exc-crash",
        "sigabrt",
        "lost-device",
        "dyld",
    }
    observed_scan_names = set(
        re.findall(r"--scan '([a-z][a-z0-9-]*)=", source)
    )
    assert observed_scan_names == required_scan_names, observed_scan_names

    # The wrapper deliberately captures/audits after the child returns, even on
    # failure, so the most useful crash evidence is not skipped.
    child_call = source.index('bash "$ROOT/scripts/device-lab/ios-simulator-smoke.sh"')
    log_capture = source.index('xcrun simctl spawn "$UDID" log show')
    child_status_check = source.index('if [[ "$child_status" != "0" ]]')
    assert child_call < log_capture < child_status_check

    # Guard the operator-owned simulator from destructive reset paths. Match
    # executable command positions, not explanatory prose.
    forbidden_commands = (
        r"(?m)^\s*xcrun\s+simctl\s+erase(?:\s|$)",
        r"(?m)^\s*xcrun\s+simctl\s+uninstall(?:\s|$)",
        r"(?m)^\s*rm\s+-rf(?:\s|$)",
    )
    for pattern in forbidden_commands:
        assert re.search(pattern, source) is None, pattern

    assert "ios-simulator-full-log-smoke.sh" in workflow
    assert "bounded-log-scan.py --self-test" in workflow
    assert "ios-simulator-log-evidence.test.py" in workflow
    assert "steps.evidence_policy.outcome == 'success'" in workflow

    # Execute one additional black-box case where the fatal marker cannot fit in
    # retained output but must appear in the machine-readable scan report.
    with tempfile.TemporaryDirectory(prefix="sonus-ios-log-contract-") as temp:
        report = Path(temp) / "report.json"
        payload = b"START\n" + b"x" * 10000 + b"EXC_CRASH" + b"y" * 10000 + b"END\n"
        result = subprocess.run(
            [
                sys.executable,
                str(REDUCER),
                "--max-bytes",
                "512",
                "--report",
                str(report),
                "--scan",
                "exc-crash=EXC_CRASH",
            ],
            input=payload,
            stdout=subprocess.PIPE,
            check=True,
        )
        retained = result.stdout
        audit = json.loads(report.read_text(encoding="utf-8"))
        assert len(retained) <= 512
        assert b"EXC_CRASH" not in retained
        assert audit["matches_total"] == 1
        assert audit["full_stream_scanned"] is True

    print(
        "iOS Simulator log evidence contract passed: full-stream scan + "
        "bounded UTF-8 head/tail + failure-path audit"
    )


if __name__ == "__main__":
    main()
