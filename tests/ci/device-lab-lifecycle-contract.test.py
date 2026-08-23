#!/usr/bin/env python3
"""Fail closed when device-lab lifecycle evidence regresses."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "scripts/device-lab/android-attached-smoke.sh"
IOS_SIMULATOR = ROOT / "scripts/device-lab/ios-simulator-smoke.sh"

android = ANDROID.read_text(encoding="utf-8")
assert 'local phase="${1:?evidence phase is required}"' in android
assert 'fatal_crash_in_phase()' in android
for filename in (
    "$phase-crash-focused-logcat.txt",
    "$phase-package-summary.txt",
    "$phase-activity-summary.txt",
    "$phase-screenshot.png",
):
    assert filename in android, filename
for phase in (
    "first-launch-failure",
    "first-launch-ui-failure",
    "first-launch",
    "home-resume-failure",
    "home-resume",
    "cold-relaunch-failure",
    "cold-relaunch",
):
    assert f"capture_crash_evidence {phase}" in android, phase
assert '"$EVIDENCE_DIR/crash-focused-logcat.txt"' not in android
assert '"$EVIDENCE_DIR/package-summary.txt"' not in android
assert '"$EVIDENCE_DIR/activity-summary.txt"' not in android
assert '"$EVIDENCE_DIR/screenshot.png"' not in android
assert android.count("fatal_crash_in_phase ") == 3

simulator = IOS_SIMULATOR.read_text(encoding="utf-8")
assert "tail -n 500" not in simulator
assert 'bounded-log.py" --max-bytes 524288' in simulator
assert simulator.count("capture_logs()") == 1
assert 'processIdentifier == $CURRENT_PID' in simulator
assert 'assert_no_fatal_logs' in simulator

print(
    "Device-lab lifecycle contract passed: 7 Android phases + bounded PID-scoped simulator logs"
)
