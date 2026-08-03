#!/usr/bin/env python3
"""Contract tests for non-overwriting physical-Android lifecycle evidence."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/device-lab/android-attached-smoke.sh"
EXPECTED_CAPTURE_PHASES = {
    "first-launch-failure",
    "first-launch-ui-failure",
    "first-launch",
    "home-resume-failure",
    "home-resume",
    "cold-relaunch-failure",
    "cold-relaunch",
}
EXPECTED_FATAL_PHASES = {"first-launch", "home-resume", "cold-relaunch"}


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

    capture = function_body(source, "capture_crash_evidence")
    assert 'local phase="${1:?evidence phase is required}"' in capture
    for suffix in (
        "crash-focused-logcat.txt",
        "package-summary.txt",
        "activity-summary.txt",
        "screenshot.png",
    ):
        assert f'$EVIDENCE_DIR/$phase-{suffix}' in capture, suffix
        assert f'$EVIDENCE_DIR/{suffix}' not in source, suffix

    fatal = function_body(source, "fatal_crash_in_phase")
    assert 'local phase="${1:?evidence phase is required}"' in fatal
    assert '$EVIDENCE_DIR/$phase-crash-focused-logcat.txt' in fatal

    capture_calls = re.findall(
        r"(?m)^\s*capture_crash_evidence(?:\s+([a-z][a-z0-9-]*))?\s*$",
        source,
    )
    assert "" not in capture_calls, "a capture call omitted its phase label"
    assert set(capture_calls) == EXPECTED_CAPTURE_PHASES, capture_calls
    assert len(capture_calls) == len(EXPECTED_CAPTURE_PHASES), capture_calls

    fatal_calls = set(
        re.findall(r"(?m)^if fatal_crash_in_phase ([a-z][a-z0-9-]*); then$", source)
    )
    assert fatal_calls == EXPECTED_FATAL_PHASES, fatal_calls

    # Preserve the non-destructive boundary for the user's USB-connected phone.
    # Match executable command positions rather than prose comments explaining
    # why destructive commands are forbidden.
    forbidden_commands = {
        "adb uninstall": r"(?m)^\s*adb(?:\s+-s\s+\S+)?\s+uninstall(?:\s|$)",
        "adb_ uninstall": r"(?m)^\s*adb_\s+uninstall(?:\s|$)",
        "pm clear": r"(?m)^\s*(?:adb_|adb(?:\s+-s\s+\S+)?)\s+shell\s+pm\s+clear(?:\s|$)",
        "logcat -c": r"(?m)^\s*(?:adb_|adb(?:\s+-s\s+\S+)?)\s+logcat\s+-c(?:\s|$)",
        "emulator wipe": r"(?m)^\s*(?:emulator|avdmanager)\b.*(?:-wipe-data|wipe-data)(?:\s|$)",
    }
    for label, pattern in forbidden_commands.items():
        assert re.search(pattern, source) is None, label

    print(
        "Android phase evidence contract passed: "
        f"{len(EXPECTED_CAPTURE_PHASES)} isolated lifecycle phases"
    )


if __name__ == "__main__":
    main()
