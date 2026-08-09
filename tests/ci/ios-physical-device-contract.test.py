#!/usr/bin/env python3
"""Executable contracts for the paired physical-iPhone Flutter harness."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/device-lab/ios-attached-smoke.sh"
MONITOR = ROOT / "scripts/device-lab/flutter-run-cycle.py"

PHYSICAL_ID = "00008120-001234567890001E"
SIMULATOR_ID = "11111111-2222-3333-4444-555555555555"
ANDROID_ID = "R58MTESTDEVICE"


def device(identifier: str, *, platform: str, target: str, emulator: bool) -> dict[str, object]:
    return {
        "id": identifier,
        "name": "synthetic-target",
        "platform": platform,
        "targetPlatform": target,
        "emulator": emulator,
        "connectionInterface": "usb" if not emulator else "local",
    }


def write_fake_flutter(path: Path) -> None:
    path.write_text(
        r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
log_path = Path(os.environ["FAKE_FLUTTER_INVOCATIONS"])
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\n")

if args[:2] == ["devices", "--machine"]:
    print(os.environ.get("FAKE_FLUTTER_DEVICES_JSON", "[]"))
    raise SystemExit(0)
if args[:2] == ["pub", "get"]:
    print("fake pub get")
    raise SystemExit(0)
if args and args[0] == "run":
    counter_path = Path(os.environ["FAKE_FLUTTER_RUN_COUNTER"])
    try:
        cycle = int(counter_path.read_text(encoding="utf-8")) + 1
    except Exception:
        cycle = 1
    counter_path.write_text(str(cycle), encoding="utf-8")
    print("launching from /Users/synthetic-user/project")
    print("Authorization: Bearer SYNTHETIC_DEVICE_TOKEN_123456789")
    print("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890")
    print("Flutter run key commands")
    sys.stdout.flush()
    if sys.stdin.readline().strip() != "q":
        print("missing quit command")
        raise SystemExit(3)
    fatal_cycle = int(os.environ.get("FAKE_FLUTTER_FATAL_CYCLE", "0"))
    if cycle == fatal_cycle:
        # This terminal marker is intentionally emitted only after q. The old
        # harness stopped reading here and incorrectly reported success.
        sys.stdout.write("Lost connection")
        sys.stdout.flush()
        sys.stdout.write(" to device\n")
        sys.stdout.flush()
    else:
        print(f"terminal-output-after-q cycle={cycle}")
        sys.stdout.flush()
    raise SystemExit(0)
print("unsupported fake flutter command", args, file=sys.stderr)
raise SystemExit(2)
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def run_case(
    temp: Path,
    name: str,
    devices: list[dict[str, object]],
    *,
    explicit_id: str | None = None,
    cycles: int = 1,
    fatal_cycle: int = 0,
) -> tuple[subprocess.CompletedProcess[str], Path, list[list[str]]]:
    case = temp / name
    fake_bin = case / "bin"
    evidence = case / "evidence"
    fake_bin.mkdir(parents=True)
    evidence.mkdir()
    fake_flutter = fake_bin / "flutter"
    write_fake_flutter(fake_flutter)
    invocations = case / "invocations.jsonl"
    counter = case / "counter.txt"

    env = os.environ.copy()
    env.update(
        {
            "PATH": str(fake_bin) + os.pathsep + env.get("PATH", ""),
            "SONUS_DEVICE_LAB_DIR": str(evidence),
            "SONUS_IOS_READY_HOLD_SECONDS": "1",
            "SONUS_IOS_RUN_TIMEOUT_SECONDS": "60",
            "SONUS_IOS_LAUNCH_CYCLES": str(cycles),
            "FAKE_FLUTTER_DEVICES_JSON": json.dumps(devices),
            "FAKE_FLUTTER_INVOCATIONS": str(invocations),
            "FAKE_FLUTTER_RUN_COUNTER": str(counter),
            "FAKE_FLUTTER_FATAL_CYCLE": str(fatal_cycle),
        }
    )
    command = ["bash", str(SCRIPT)]
    if explicit_id is not None:
        command.append(explicit_id)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
        check=False,
    )
    rows = []
    if invocations.exists():
        rows = [json.loads(line) for line in invocations.read_text(encoding="utf-8").splitlines()]
    return result, evidence, rows


def assert_redacted(evidence: Path) -> None:
    text = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in evidence.rglob("*")
        if path.is_file()
    )
    assert "/Users/synthetic-user" not in text
    assert "SYNTHETIC_DEVICE_TOKEN" not in text
    assert "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ" not in text


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
    subprocess.run([sys.executable, "-m", "py_compile", str(MONITOR)], check=True)
    subprocess.run([sys.executable, str(MONITOR), "--self-test"], check=True)

    assert 'python3 "$CYCLE_MONITOR"' in source
    assert 'python3 "$EVIDENCE_POLICY" --stream' in source
    assert 'terminal_output_drained=true' in source
    assert 'fatal_runtime_markers_checked=true' in source
    assert "selectors" not in source, "the inline monitor should remain extracted"

    physical = device(PHYSICAL_ID, platform="ios", target="ios-arm64", emulator=False)
    simulator = device(SIMULATOR_ID, platform="ios", target="ios", emulator=True)
    android = device(ANDROID_ID, platform="android", target="android-arm64", emulator=False)

    with tempfile.TemporaryDirectory(prefix="sonus-ios-physical-contract-") as raw_temp:
        temp = Path(raw_temp)

        success, evidence, calls = run_case(
            temp,
            "success",
            [simulator, android, physical],
            cycles=2,
        )
        assert success.returncode == 0, success.stdout
        run_calls = [row for row in calls if row and row[0] == "run"]
        assert len(run_calls) == 2, calls
        for row in run_calls:
            index = row.index("-d")
            assert row[index + 1] == PHYSICAL_ID
        result = (evidence / "result.txt").read_text(encoding="utf-8")
        assert "launch_cycles_completed=2" in result
        assert "terminal_output_drained=true" in result
        for label in ("first-launch", "cold-relaunch-2"):
            report = json.loads((evidence / f"{label}-cycle.json").read_text(encoding="utf-8"))
            assert report["status"] == "passed"
            assert report["terminal_output_drained"] is True
            assert report["fatal_markers"] == []
            assert "terminal-output-after-q" in (evidence / f"{label}-flutter-run.txt").read_text(encoding="utf-8")
        assert_redacted(evidence)

        fatal, fatal_evidence, _ = run_case(
            temp,
            "fatal-after-quit",
            [physical],
            fatal_cycle=1,
        )
        assert fatal.returncode != 0, fatal.stdout
        fatal_report = json.loads((fatal_evidence / "first-launch-cycle.json").read_text(encoding="utf-8"))
        assert fatal_report["status"] == "failed"
        assert fatal_report["terminal_output_drained"] is True
        assert fatal_report["fatal_markers"] == ["Lost connection to device"]
        assert "Lost connection to device" in (fatal_evidence / "first-launch-flutter-run.txt").read_text(encoding="utf-8")
        assert_redacted(fatal_evidence)

        rejected_cases = (
            ("explicit-simulator", [physical, simulator], SIMULATOR_ID),
            ("explicit-android", [physical, android], ANDROID_ID),
            ("stale-id", [physical], "stale-device-id"),
        )
        for name, devices, requested in rejected_cases:
            rejected, _, rejected_calls = run_case(
                temp,
                name,
                devices,
                explicit_id=requested,
            )
            assert rejected.returncode == 78, (name, rejected.returncode, rejected.stdout)
            assert not any(row and row[0] == "run" for row in rejected_calls)

        second_physical = device(
            "00008130-00ABCDEF1234002E",
            platform="ios",
            target="ios-arm64",
            emulator=False,
        )
        ambiguous, _, ambiguous_calls = run_case(
            temp,
            "ambiguous",
            [physical, second_physical],
        )
        assert ambiguous.returncode == 78, ambiguous.stdout
        assert not any(row and row[0] == "run" for row in ambiguous_calls)

    print(
        "Physical iPhone contract passed: unique selection + two launches + "
        "post-quit drain + fatal-tail rejection + simulator/Android/stale/ambiguous refusal"
    )


if __name__ == "__main__":
    main()
