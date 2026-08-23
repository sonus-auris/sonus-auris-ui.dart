#!/usr/bin/env python3
"""Executable fake-ADB contracts for the physical Android device lab."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/device-lab/android-attached-smoke.sh"
POLICY = ROOT / "scripts/device-lab/evidence-policy.py"
PHYSICAL = "USB-SYNTHETIC-001"
EMULATOR = "emulator-5554"
TCP_EMULATOR = "127.0.0.1:5555"

SECRET_FIXTURES = (
    "/Users/synthetic-android-user/project",
    "Bearer SYNTHETIC_ANDROID_BEARER_123456789",
    "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
    "123e4567-e89b-42d3-a456-426614174000",
    "synthetic.android@example.com",
    "access_token=SYNTHETIC_ANDROID_ACCESS_TOKEN",
)


def write_fake_sleep(path: Path) -> None:
    path.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def write_fake_adb(path: Path) -> None:
    path.write_text(
        r'''#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
state = Path(os.environ["FAKE_ADB_STATE_DIR"])
state.mkdir(parents=True, exist_ok=True)
commands = state / "commands.jsonl"
with commands.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(args) + "\n")

devices = json.loads(os.environ.get("FAKE_ADB_DEVICES_JSON", "[]"))
by_serial = {row["serial"]: row for row in devices}


def read_int(name: str, default: int = 0) -> int:
    path = state / name
    try:
        return int(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_int(name: str, value: int) -> None:
    (state / name).write_text(str(value), encoding="utf-8")


def secret_lines() -> None:
    if os.environ.get("FAKE_ADB_SECRET_FIXTURES") == "1":
        print("checkout=/Users/synthetic-android-user/project")
        print("Authorization: Bearer SYNTHETIC_ANDROID_BEARER_123456789")
        print("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890")
        print("session=123e4567-e89b-42d3-a456-426614174000")
        print("email=synthetic.android@example.com")
        print("access_token=SYNTHETIC_ANDROID_ACCESS_TOKEN")


if args == ["devices"]:
    print("List of devices attached")
    for row in devices:
        print(f"{row['serial']}\t{row.get('state', 'device')}")
    raise SystemExit(0)

serial = None
if len(args) >= 2 and args[0] == "-s":
    serial = args[1]
    args = args[2:]
if serial is None or serial not in by_serial:
    print("unknown or missing synthetic serial", file=sys.stderr)
    raise SystemExit(2)
row = by_serial[serial]

if args[:2] == ["shell", "getprop"] and len(args) == 3:
    prop = args[2]
    values = {
        "ro.kernel.qemu": "1" if row.get("qemu") else "0",
        "ro.product.manufacturer": "Synthetic",
        "ro.product.model": "Android Lab Device",
        "ro.build.version.release": "14",
        "ro.build.version.sdk": "34",
        "ro.build.version.security_patch": "2026-08-01",
    }
    print(values.get(prop, ""))
    raise SystemExit(0)

if args[:3] == ["shell", "pm", "path"]:
    existing = os.environ.get("FAKE_ADB_EXISTING_PACKAGE", "1") == "1"
    installed = (state / "installed").exists()
    if existing or installed:
        print("package:/data/app/synthetic/base.apk")
        raise SystemExit(0)
    raise SystemExit(1)

if args[:3] == ["shell", "dumpsys", "package"]:
    after = (state / "installed").exists()
    before_time = os.environ.get("FAKE_ADB_FIRST_INSTALL_BEFORE", "2026-07-01 00:00:00")
    after_time = os.environ.get("FAKE_ADB_FIRST_INSTALL_AFTER", before_time)
    before_grant = os.environ.get("FAKE_ADB_PERMISSION_BEFORE", "true")
    after_grant = os.environ.get("FAKE_ADB_PERMISSION_AFTER", before_grant)
    first_install = after_time if after else before_time
    grant = after_grant if after else before_grant
    print("Packages:")
    print("  Package [com.ores.sonus_auris]:")
    print("    versionCode=42 minSdk=24 targetSdk=34")
    print("    versionName=0.0.synthetic")
    print("    targetSdk=34")
    print(f"    firstInstallTime={first_install}")
    print("    runtime permissions:")
    print(f"      android.permission.RECORD_AUDIO: granted={grant}, flags=[ USER_SET ]")
    print("      android.permission.POST_NOTIFICATIONS: granted=false, flags=[ ]")
    raise SystemExit(0)

if args[:2] == ["install", "-r"]:
    secret_lines()
    if os.environ.get("FAKE_ADB_INSTALL_FAIL") == "1":
        print("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]")
        raise SystemExit(1)
    (state / "installed").write_text("1", encoding="utf-8")
    print("Success")
    raise SystemExit(0)

if args == ["shell", "date", "+%s"]:
    print(1700000000 + read_int("launch_count") * 10)
    raise SystemExit(0)

if args[:3] == ["shell", "am", "start"]:
    cycle = read_int("launch_count") + 1
    write_int("launch_count", cycle)
    write_int("running", 1)
    secret_lines()
    print("Starting: Intent { act=android.intent.action.MAIN }")
    print("Status: ok")
    print("LaunchState: COLD")
    raise SystemExit(0)

if args[:3] == ["shell", "pidof", "com.ores.sonus_auris"]:
    if read_int("running"):
        print(4100 + read_int("launch_count"))
        raise SystemExit(0)
    raise SystemExit(1)

if args[:3] == ["shell", "uiautomator", "dump"]:
    if os.environ.get("FAKE_ADB_MISSING_UI") == "1":
        print("UI hierarchy dumped to: /dev/tty")
    else:
        print('<?xml version="1.0" encoding="UTF-8"?>')
        print('<hierarchy><node text="Sonus Auris" content-desc="Welcome to Sonus Auris" /></hierarchy>')
    raise SystemExit(0)

if args[:3] == ["logcat", "-d", "-v"]:
    cycle = read_int("launch_count")
    secret_lines()
    fatal = int(os.environ.get("FAKE_ADB_FATAL_CYCLE", "0"))
    timestamp = 1700000100 + cycle * 10
    print(f"{timestamp}.000  100  100 I flutter: Sonus Auris cycle {cycle}")
    if cycle == fatal:
        print(f"{timestamp}.100  100  100 E AndroidRuntime: FATAL EXCEPTION: main")
        print(
            f"{timestamp}.200  100  100 E ActivityManager: "
            "Process com.ores.sonus_auris (pid 999) has died"
        )
    raise SystemExit(0)

if args[:4] == ["shell", "dumpsys", "activity", "activities"]:
    print("mResumedActivity: ActivityRecord{synthetic com.ores.sonus_auris/.MainActivity}")
    raise SystemExit(0)

if args[:4] == ["shell", "input", "keyevent", "KEYCODE_HOME"]:
    if os.environ.get("FAKE_ADB_HOME_KILLS") == "1":
        write_int("running", 0)
    raise SystemExit(0)

if args[:3] == ["shell", "am", "force-stop"]:
    write_int("running", 0)
    raise SystemExit(0)

if args[:3] == ["exec-out", "screencap", "-p"]:
    sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n")
    raise SystemExit(0)

print("unsupported fake adb command: " + json.dumps(args), file=sys.stderr)
raise SystemExit(2)
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def device(serial: str, *, state: str = "device", qemu: bool = False) -> dict[str, object]:
    return {"serial": serial, "state": state, "qemu": qemu}


def run_case(
    temp: Path,
    name: str,
    devices: list[dict[str, object]],
    *,
    explicit_serial: str | None = None,
    existing_package: bool = True,
    require_ui: bool = True,
    fatal_cycle: int = 0,
    missing_ui: bool = False,
    install_fail: bool = False,
    first_install_after: str | None = None,
    permission_after: str | None = None,
    secret_fixtures: bool = False,
) -> tuple[subprocess.CompletedProcess[str], Path, list[list[str]]]:
    case = temp / name
    fake_bin = case / "bin"
    evidence = case / "evidence"
    state = case / "state"
    fake_bin.mkdir(parents=True)
    evidence.mkdir()
    state.mkdir()
    write_fake_adb(fake_bin / "adb")
    write_fake_sleep(fake_bin / "sleep")
    apk = case / "app-debug.apk"
    apk.write_bytes(b"synthetic-apk")

    env = os.environ.copy()
    env.update(
        {
            "PATH": str(fake_bin) + os.pathsep + env.get("PATH", ""),
            "SONUS_DEVICE_LAB_DIR": str(evidence),
            "SONUS_REQUIRE_ANDROID_UI": "1" if require_ui else "0",
            "SONUS_CAPTURE_SCREENSHOT": "0",
            "SONUS_REQUIRE_PACKAGE_STATE_PRESERVATION": "1",
            "FAKE_ADB_STATE_DIR": str(state),
            "FAKE_ADB_DEVICES_JSON": json.dumps(devices),
            "FAKE_ADB_EXISTING_PACKAGE": "1" if existing_package else "0",
            "FAKE_ADB_FATAL_CYCLE": str(fatal_cycle),
            "FAKE_ADB_MISSING_UI": "1" if missing_ui else "0",
            "FAKE_ADB_INSTALL_FAIL": "1" if install_fail else "0",
            "FAKE_ADB_SECRET_FIXTURES": "1" if secret_fixtures else "0",
        }
    )
    if first_install_after is not None:
        env["FAKE_ADB_FIRST_INSTALL_AFTER"] = first_install_after
    if permission_after is not None:
        env["FAKE_ADB_PERMISSION_AFTER"] = permission_after

    command = ["bash", str(SCRIPT), str(apk)]
    if explicit_serial is not None:
        command.append(explicit_serial)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=20,
        check=False,
    )

    # Model the upload path: every retained text file must pass the shared final
    # policy on success and failure alike.
    if evidence.exists() and any(evidence.iterdir()):
        policy = subprocess.run(
            [sys.executable, str(POLICY), "--redact", str(evidence)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
        assert policy.returncode == 0, (name, policy.stdout)

    command_log = state / "commands.jsonl"
    rows = []
    if command_log.exists():
        rows = [
            json.loads(line)
            for line in command_log.read_text(encoding="utf-8").splitlines()
        ]
    return result, evidence, rows


def assert_no_destructive_commands(rows: list[list[str]]) -> None:
    joined = [" ".join(row) for row in rows]
    forbidden = (
        " uninstall ",
        " pm clear ",
        " logcat -c",
        " pm grant ",
        " pm revoke ",
        " settings put ",
        " wipe-data",
    )
    padded = [f" {row} " for row in joined]
    for marker in forbidden:
        assert not any(marker in row for row in padded), (marker, joined)


def assert_fixture_redaction(evidence: Path) -> None:
    retained = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in evidence.rglob("*")
        if path.is_file()
        and path.suffix.lower() in {".txt", ".log", ".json", ".sha256"}
    )
    for fixture in SECRET_FIXTURES:
        assert fixture not in retained, fixture
    assert "<redacted" in retained


def main() -> None:
    source = SCRIPT.read_text(encoding="utf-8")
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
    subprocess.run([sys.executable, "-m", "py_compile", str(POLICY)], check=True)

    with tempfile.TemporaryDirectory(prefix="sonus-android-contract-") as raw_temp:
        temp = Path(raw_temp)

        success, evidence, rows = run_case(
            temp,
            "success-existing",
            [device(EMULATOR, qemu=True), device(PHYSICAL)],
            secret_fixtures=True,
        )
        assert success.returncode == 0, success.stdout
        result = (evidence / "result.txt").read_text(encoding="utf-8")
        assert "status=passed" in result
        assert "existing_package=true" in result
        assert "package_state_preserved=true" in result
        assert "app_data_cleared=false" in result
        assert "permissions_mutated=false" in result
        assert "log_buffer_cleared=false" in result
        assert "home_resume_completed=true" in result
        assert "process_survived_home=true" in result
        assert "target_fingerprint=" in (evidence / "target.txt").read_text(
            encoding="utf-8"
        )
        expected_phase_files = {
            f"{phase}-{suffix}"
            for phase in ("first-launch", "home-resume", "cold-relaunch")
            for suffix in (
                "crash-focused-logcat.txt",
                "package-summary.txt",
                "activity-summary.txt",
            )
        }
        assert expected_phase_files.issubset({p.name for p in evidence.iterdir()})
        assert not any(
            (evidence / name).exists()
            for name in (
                "crash-focused-logcat.txt",
                "package-summary.txt",
                "activity-summary.txt",
            )
        )
        starts = [
            row
            for row in rows
            if row[:5] == ["-s", PHYSICAL, "shell", "am", "start"]
        ]
        assert len(starts) == 3, rows
        assert any(row[:4] == ["-s", PHYSICAL, "install", "-r"] for row in rows)
        assert any(
            row[-4:] == ["shell", "input", "keyevent", "KEYCODE_HOME"]
            for row in rows
        )
        assert any(
            row[:5] == ["-s", PHYSICAL, "shell", "am", "force-stop"]
            for row in rows
        )
        assert_no_destructive_commands(rows)
        assert_fixture_redaction(evidence)

        fresh, fresh_evidence, fresh_rows = run_case(
            temp,
            "success-fresh",
            [device(PHYSICAL)],
            explicit_serial=PHYSICAL,
            existing_package=False,
        )
        assert fresh.returncode == 0, fresh.stdout
        fresh_result = (fresh_evidence / "result.txt").read_text(encoding="utf-8")
        assert "existing_package=false" in fresh_result
        assert "package_state_preserved=not-applicable" in fresh_result
        assert_no_destructive_commands(fresh_rows)

        rejected_cases = (
            (
                "tcp-emulator",
                [device(TCP_EMULATOR, qemu=True)],
                TCP_EMULATOR,
                3,
            ),
            (
                "unauthorized",
                [device(PHYSICAL, state="unauthorized")],
                PHYSICAL,
                3,
            ),
        )
        for name, devices, serial, expected_code in rejected_cases:
            rejected, _, rejected_rows = run_case(
                temp,
                name,
                devices,
                explicit_serial=serial,
            )
            assert rejected.returncode == expected_code, (
                name,
                rejected.returncode,
                rejected.stdout,
            )
            assert not any(
                " install " in f" {' '.join(row)} " for row in rejected_rows
            )
            assert_no_destructive_commands(rejected_rows)

        ambiguous, _, ambiguous_rows = run_case(
            temp,
            "ambiguous",
            [device(PHYSICAL), device("USB-SYNTHETIC-002")],
        )
        assert ambiguous.returncode == 3, ambiguous.stdout
        assert not any(" install " in f" {' '.join(row)} " for row in ambiguous_rows)
        assert_no_destructive_commands(ambiguous_rows)

        signing, signing_evidence, signing_rows = run_case(
            temp,
            "signing-mismatch",
            [device(PHYSICAL)],
            explicit_serial=PHYSICAL,
            install_fail=True,
        )
        assert signing.returncode == 5, signing.stdout
        assert "will not uninstall" in signing.stdout
        assert (signing_evidence / "install.txt").exists()
        assert_no_destructive_commands(signing_rows)

        state_drift, drift_evidence, drift_rows = run_case(
            temp,
            "package-state-drift",
            [device(PHYSICAL)],
            explicit_serial=PHYSICAL,
            first_install_after="2026-08-03 00:00:00",
        )
        assert state_drift.returncode == 12, state_drift.stdout
        preservation = (drift_evidence / "package-preservation.txt").read_text(
            encoding="utf-8"
        )
        assert "status=failed" in preservation
        assert "first_install_time_changed" in preservation
        assert_no_destructive_commands(drift_rows)

        missing_ui, missing_evidence, missing_rows = run_case(
            temp,
            "missing-ui",
            [device(PHYSICAL)],
            explicit_serial=PHYSICAL,
            missing_ui=True,
        )
        assert missing_ui.returncode == 7, missing_ui.stdout
        assert (
            missing_evidence / "first-launch-ui-failure-crash-focused-logcat.txt"
        ).exists()
        assert_no_destructive_commands(missing_rows)

        fatal_expectations = {1: 8, 2: 10, 3: 14}
        phase_names = {1: "first-launch", 2: "home-resume", 3: "cold-relaunch"}
        for cycle, expected_code in fatal_expectations.items():
            failed, failed_evidence, failed_rows = run_case(
                temp,
                f"fatal-cycle-{cycle}",
                [device(PHYSICAL)],
                explicit_serial=PHYSICAL,
                fatal_cycle=cycle,
            )
            assert failed.returncode == expected_code, (
                cycle,
                failed.returncode,
                failed.stdout,
            )
            phase = phase_names[cycle]
            fatal_log = failed_evidence / f"{phase}-crash-focused-logcat.txt"
            assert fatal_log.exists()
            assert "FATAL EXCEPTION" in fatal_log.read_text(encoding="utf-8")
            assert_no_destructive_commands(failed_rows)

    # Keep a static fallback that catches destructive additions even if the fake
    # matrix fails before command logging is initialized.
    forbidden_source_commands = (
        r"(?m)^\s*adb(?:\s+-s\s+\S+)?\s+uninstall(?:\s|$)",
        r"(?m)^\s*adb_\s+uninstall(?:\s|$)",
        r"(?m)^\s*(?:adb_|adb(?:\s+-s\s+\S+)?)\s+shell\s+pm\s+clear(?:\s|$)",
        r"(?m)^\s*(?:adb_|adb(?:\s+-s\s+\S+)?)\s+logcat\s+-c(?:\s|$)",
    )
    for pattern in forbidden_source_commands:
        assert re.search(pattern, source) is None, pattern

    print(
        "Physical Android contract passed: install/update + three lifecycle phases + "
        "fresh/existing state + fatal isolation + UI/signing/state failures + "
        "emulator/unauthorized/ambiguous refusal + destructive-command absence"
    )


if __name__ == "__main__":
    main()
