#!/usr/bin/env python3
"""Contracts for bounded, redacted iOS Simulator lifecycle logs."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/device-lab/ios-simulator-smoke.sh"
POLICY = ROOT / "scripts/device-lab/evidence-policy.py"
BOUNDER = ROOT / "scripts/device-lab/bounded-log.py"


def function_body(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^{re.escape(name)}\(\) \{{\n(?P<body>.*?)^\}}\n",
        source,
    )
    if not match:
        raise AssertionError(f"missing shell function: {name}")
    return match.group("body")


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    sanitizer = function_body(source, "sanitize_stream")
    assert sanitizer.strip() == (
        'python3 "$ROOT/scripts/device-lab/evidence-policy.py" --stream'
    )
    assert "sys.stdin.read()" not in source

    capture = function_body(source, "capture_logs")
    assert 'predicate="processIdentifier == $CURRENT_PID"' in capture
    assert "| sanitize_stream \\" in capture
    assert (
        '| python3 "$ROOT/scripts/device-lab/bounded-log.py" '
        "--max-bytes 524288 \\" in capture
    )
    assert '$EVIDENCE_DIR/$label-simulator.log' in capture
    assert "tail -n 500" not in capture

    for marker in (
        "process_scoped_logs=true",
        "streaming_redaction=true",
        "startup_log_context_preserved=true",
        "simulator_log_max_bytes=524288",
    ):
        assert marker in source, marker

    subprocess.run([sys.executable, str(BOUNDER), "--self-test"], check=True)

    raw = (
        "BOOT /Users/synthetic-user/AppIcon60x60@2x.png\n"
        + "middle event\n" * 10000
        + "TERMINAL Authorization: Bearer SYNTHETIC_SECRET_12345\n"
    ).encode("utf-8")
    sanitized = subprocess.run(
        [sys.executable, str(POLICY), "--stream"],
        input=raw,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    assert b"synthetic-user" not in sanitized
    assert b"SYNTHETIC_SECRET_12345" not in sanitized
    assert b"AppIcon60x60@2x.png" in sanitized

    bounded = subprocess.run(
        [sys.executable, str(BOUNDER), "--max-bytes", "1024"],
        input=sanitized,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    ).stdout
    assert len(bounded) <= 1024
    assert bounded.startswith(b"BOOT /Users/<redacted>/AppIcon60x60@2x.png\n")
    assert bounded.endswith(b"TERMINAL Authorization: Bearer <redacted>\n")
    assert b"sonus-log-truncated" in bounded
    assert b"synthetic-user" not in bounded
    assert b"SYNTHETIC_SECRET_12345" not in bounded

    print(
        "iOS Simulator log-retention contract passed: streaming redaction + "
        "bounded startup/tail context"
    )


if __name__ == "__main__":
    main()
