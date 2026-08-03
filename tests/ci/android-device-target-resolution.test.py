#!/usr/bin/env python3
"""Contracts for deterministic physical-Android selection in the Mac device lab."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts/device-lab/resolve-physical-android.py"
ORCHESTRATOR = ROOT / "scripts/device-lab/macos-end-device-smoke.sh"
EXIT_NO_TARGET = 78
EXIT_UNSAFE_SELECTION = 79
HEADER = "List of devices attached\n"


def adb_row(serial: str, state: str = "device") -> str:
    return f"{serial}\t{state} product:test model:private transport_id:1\n"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def create_fake_adb(directory: Path) -> Path:
    path = directory / "adb"
    write_executable(
        path,
        """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
if args == ["devices", "-l"]:
    if os.environ.get("FAKE_ADB_DISCOVERY_FAILURE") == "1":
        raise SystemExit(1)
    sys.stdout.write(os.environ.get("FAKE_ADB_DEVICES", "List of devices attached\\n"))
    raise SystemExit(0)
if len(args) == 5 and args[0] == "-s" and args[2:] == ["shell", "getprop", "ro.kernel.qemu"]:
    serial = args[1]
    failures = set(json.loads(os.environ.get("FAKE_ADB_PROBE_FAILURES", "[]")))
    if serial in failures:
        raise SystemExit(1)
    mapping = json.loads(os.environ.get("FAKE_ADB_QEMU", "{}"))
    sys.stdout.write(str(mapping.get(serial, "")) + "\\n")
    raise SystemExit(0)
raise SystemExit(2)
""",
    )
    return path


def run_resolver(
    devices: str,
    qemu: dict[str, object],
    *,
    explicit: str | None = None,
    probe_failures: list[str] | None = None,
    discovery_failure: bool = False,
) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        fake_bin = Path(directory)
        adb = create_fake_adb(fake_bin)
        command = [sys.executable, str(RESOLVER), "--adb", str(adb)]
        if explicit is not None:
            command.extend(["--serial", explicit])
        env = os.environ.copy()
        env.update(
            {
                "FAKE_ADB_DEVICES": devices,
                "FAKE_ADB_QEMU": json.dumps(qemu),
                "FAKE_ADB_PROBE_FAILURES": json.dumps(probe_failures or []),
                "FAKE_ADB_DISCOVERY_FAILURE": "1" if discovery_failure else "0",
            }
        )
        return subprocess.run(
            command,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=15,
        )


def run_orchestrator_case(
    devices: str,
    qemu: dict[str, object],
    *,
    mode: str,
    child_status: int = 0,
    explicit: str | None = None,
    probe_failures: list[str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        scripts = root / "scripts" / "device-lab"
        scripts.mkdir(parents=True)
        shutil.copy2(ORCHESTRATOR, scripts / ORCHESTRATOR.name)
        shutil.copy2(RESOLVER, scripts / RESOLVER.name)
        (scripts / "resolve-physical-ios.py").write_text(
            "#!/usr/bin/env python3\nraise SystemExit(78)\n",
            encoding="utf-8",
        )
        (scripts / "evidence-policy.py").write_text(
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
            encoding="utf-8",
        )
        write_executable(
            scripts / "android-attached-smoke.sh",
            "#!/usr/bin/env bash\nexit \"${FAKE_CHILD_STATUS:-0}\"\n",
        )

        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        write_executable(fake_bin / "uname", "#!/usr/bin/env bash\necho Darwin\n")
        create_fake_adb(fake_bin)

        evidence = root / "evidence"
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "FAKE_ADB_DEVICES": devices,
                "FAKE_ADB_QEMU": json.dumps(qemu),
                "FAKE_ADB_PROBE_FAILURES": json.dumps(probe_failures or []),
                "FAKE_CHILD_STATUS": str(child_status),
                "SONUS_DEVICE_LAB_DIR": str(evidence),
                "SONUS_RUN_IOS_SIMULATOR": "0",
                "SONUS_RUN_IOS_DEVICE": "0",
                "SONUS_RUN_ANDROID_DEVICE": mode,
                "SONUS_RUN_FLUTTER_MACOS": "0",
            }
        )
        if explicit is not None:
            env["ANDROID_SERIAL"] = explicit
        else:
            env.pop("ANDROID_SERIAL", None)

        output_path = root / "orchestrator-output.txt"
        with output_path.open("w", encoding="utf-8") as output_handle:
            raw_completed = subprocess.run(
                ["bash", str(scripts / ORCHESTRATOR.name)],
                cwd=root,
                env=env,
                text=True,
                stdout=output_handle,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=25,
            )
        output = output_path.read_text(encoding="utf-8", errors="replace")
        completed = subprocess.CompletedProcess(
            raw_completed.args,
            raw_completed.returncode,
            stdout=output,
            stderr="",
        )
        results: dict[str, str] = {}
        results_path = evidence / "results.txt"
        if results_path.is_file():
            for line in results_path.read_text(encoding="utf-8").splitlines():
                if "=" in line:
                    key, value = line.split("=", 1)
                    results[key] = value
        return completed, results


def function_body(source: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^{re.escape(name)}\(\) \{{\n(?P<body>.*?)^\}}\n",
        source,
    )
    if not match:
        raise AssertionError(f"missing shell function: {name}")
    return match.group("body")


def validate_orchestrator(source: str) -> None:
    assert 'ANDROID_RESOLVER="$ROOT/scripts/device-lab/resolve-physical-android.py"' in source
    assert "physical_android_targets" not in source

    selector = function_body(source, "select_physical_android")
    assert "command -v adb" in selector
    assert 'resolver_args+=(--serial "$ANDROID_SERIAL")' in selector
    assert 'python3 "$ANDROID_RESOLVER" "${resolver_args[@]}"' in selector
    assert 'printf \'%s\\n\' "$ANDROID_SERIAL"' not in selector

    required_start = source.index('case "$RUN_ANDROID_DEVICE" in')
    required_case = re.search(
        r"(?ms)^  1\|true\|yes\)\n(?P<body>.*?)^    ;;$",
        source[required_start:],
    )
    assert required_case
    required_body = required_case.group("body")
    assert 'android_serial="$(select_physical_android)"' in required_body
    assert "SONUS_TARGET_REQUIRED=1 run_target android-device" in required_body
    assert '"$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"' in required_body
    assert "record_status android-device failed" in required_body

    auto_case = re.search(
        r"(?ms)^  auto\)\n(?P<body>.*?)^    ;;$",
        source[required_start:],
    )
    assert auto_case
    auto_body = auto_case.group("body")
    assert '"$selection_status" == "78"' in auto_body
    assert "record_status android-device skipped" in auto_body
    assert "Physical Android target selection was ambiguous or unsafe." in auto_body
    assert "record_status android-device failed" in auto_body
    assert '"$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"' in auto_body

    assert "physical_android_preselected=true" in source
    assert "android_emulator_probe=ro.kernel.qemu" in source
    assert "required_target_exit_78_is_failure=true" in source


def assert_no_identifier_leak(result: subprocess.CompletedProcess[str], ids: list[str]) -> None:
    for serial in ids:
        assert serial not in result.stderr


def main() -> None:
    subprocess.run([sys.executable, "-m", "py_compile", str(RESOLVER)], check=True)
    subprocess.run([sys.executable, str(RESOLVER), "--self-test"], check=True)
    subprocess.run(["bash", "-n", str(ORCHESTRATOR)], check=True)

    phone = "usb-phone"
    phone_two = "usb-phone-two"
    tcp_phone = "192.0.2.10:5555"
    emulator = "emulator-5554"
    tcp_emulator = "127.0.0.1:5555"
    locked = "usb-locked"
    offline = "usb-offline"
    known = [phone, phone_two, tcp_phone, emulator, tcp_emulator, locked, offline, "missing-serial-xyz"]

    cases = [
        (HEADER + adb_row(phone), {phone: ""}, None, None, 0, phone),
        (
            HEADER + adb_row(emulator) + adb_row(tcp_emulator) + adb_row(phone),
            {emulator: "1", tcp_emulator: "1", phone: "0"},
            None,
            None,
            0,
            phone,
        ),
        (HEADER + adb_row(tcp_phone), {tcp_phone: "0"}, None, None, 0, tcp_phone),
        (HEADER + adb_row(emulator) + adb_row(tcp_emulator), {emulator: "1", tcp_emulator: "1"}, None, None, EXIT_NO_TARGET, ""),
        (HEADER + adb_row(phone) + adb_row(phone_two), {phone: "0", phone_two: "0"}, None, None, EXIT_UNSAFE_SELECTION, ""),
        (HEADER + adb_row(locked, "unauthorized") + adb_row(offline, "offline"), {}, None, None, EXIT_NO_TARGET, ""),
        (HEADER + adb_row(phone), {phone: "0"}, "missing-serial-xyz", None, EXIT_UNSAFE_SELECTION, ""),
        (HEADER + adb_row(tcp_emulator), {tcp_emulator: "1"}, tcp_emulator, None, EXIT_UNSAFE_SELECTION, ""),
        (HEADER + adb_row(phone), {phone: "0"}, None, [phone], EXIT_UNSAFE_SELECTION, ""),
        (HEADER + adb_row(phone), {phone: "unexpected"}, None, None, EXIT_UNSAFE_SELECTION, ""),
    ]

    for devices, qemu, explicit, failures, expected_code, expected_stdout in cases:
        result = run_resolver(
            devices,
            qemu,
            explicit=explicit,
            probe_failures=failures,
        )
        assert result.returncode == expected_code, (result.returncode, result.stderr)
        assert result.stdout.strip() == expected_stdout
        if expected_code != 0:
            assert_no_identifier_leak(result, known)

    malformed = run_resolver("not-adb-output\n", {})
    assert malformed.returncode == EXIT_UNSAFE_SELECTION
    assert "malformed" in malformed.stderr.lower()
    discovery_failure = run_resolver(HEADER, {}, discovery_failure=True)
    assert discovery_failure.returncode == EXIT_UNSAFE_SELECTION
    assert "unavailable" in discovery_failure.stderr.lower()

    # Execute the full Bash orchestrator with fake ADB and child commands.
    leak_checked_runs: list[subprocess.CompletedProcess[str]] = []
    completed, results = run_orchestrator_case(
        HEADER + adb_row(phone),
        {phone: "0"},
        mode="1",
        child_status=0,
    )
    assert completed.returncode == 0, completed.stderr
    assert results["android-device"] == "passed"
    leak_checked_runs.append(completed)

    completed, results = run_orchestrator_case(
        HEADER + adb_row(phone),
        {phone: "0"},
        mode="1",
        child_status=78,
    )
    assert completed.returncode == 1
    assert results["android-device"] == "failed"

    completed, results = run_orchestrator_case(HEADER, {}, mode="auto")
    assert completed.returncode == 0
    assert results["android-device"] == "skipped"

    completed, results = run_orchestrator_case(
        HEADER + adb_row(phone) + adb_row(phone_two),
        {phone: "0", phone_two: "0"},
        mode="auto",
    )
    assert completed.returncode == 1
    assert results["android-device"] == "failed"
    leak_checked_runs.append(completed)

    completed, results = run_orchestrator_case(
        HEADER + adb_row(tcp_emulator),
        {tcp_emulator: "1"},
        mode="auto",
    )
    assert completed.returncode == 0
    assert results["android-device"] == "skipped"

    completed, results = run_orchestrator_case(
        HEADER + adb_row(tcp_emulator),
        {tcp_emulator: "1"},
        mode="1",
        explicit=tcp_emulator,
    )
    assert completed.returncode == 1
    assert results["android-device"] == "failed"
    leak_checked_runs.append(completed)

    completed, results = run_orchestrator_case(
        HEADER + adb_row(phone),
        {phone: "0"},
        mode="auto",
        probe_failures=[phone],
    )
    assert completed.returncode == 1
    assert results["android-device"] == "failed"

    for completed in leak_checked_runs:
        assert_no_identifier_leak(completed, known)

    source = ORCHESTRATOR.read_text(encoding="utf-8")
    validate_orchestrator(source)
    mutations = (
        source.replace(
            'python3 "$ANDROID_RESOLVER" "${resolver_args[@]}"',
            'printf \'%s\\n\' "$ANDROID_SERIAL"',
            1,
        ),
        source.replace('resolver_args+=(--serial "$ANDROID_SERIAL")', ":", 1),
        source.replace('"$selection_status" == "78"', '"$selection_status" != "0"', 1),
        source.replace("SONUS_TARGET_REQUIRED=1 run_target android-device", "run_target android-device", 1),
        source.replace('"$ROOT/build/app/outputs/flutter-apk/app-debug.apk" "$android_serial"', '"$ROOT/build/app/outputs/flutter-apk/app-debug.apk"', 1),
        source.replace("android_emulator_probe=ro.kernel.qemu", "android_emulator_probe=none", 1),
    )
    for mutated in mutations:
        try:
            validate_orchestrator(mutated)
        except AssertionError:
            pass
        else:
            raise AssertionError("unsafe Android orchestration mutation unexpectedly passed")

    print(
        "physical Android target-resolution contract passed: resolver self-test + "
        "10 CLI cases + malformed/discovery failure + 7 executable orchestration cases + "
        "6 mutation refusals"
    )


if __name__ == "__main__":
    main()
