#!/usr/bin/env python3
"""Contracts for deterministic physical-iOS selection in the Mac device lab."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts/device-lab/resolve-physical-ios.py"
ORCHESTRATOR = ROOT / "scripts/device-lab/macos-end-device-smoke.sh"
EXIT_NO_TARGET = 78
EXIT_UNSAFE_SELECTION = 79


def device(
    device_id: str,
    *,
    platform: str = "ios",
    target: str = "ios",
    emulator: object = False,
    supported: object = True,
) -> dict[str, Any]:
    return {
        "id": device_id,
        "name": "private device name",
        "platform": platform,
        "targetPlatform": target,
        "emulator": emulator,
        "isSupported": supported,
        "connectionInterface": "wireless",
    }


def run_resolver(payload: object, explicit: str | None = None) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(RESOLVER)]
    if explicit is not None:
        command.extend(["--device-id", explicit])
    return subprocess.run(
        command,
        input=json.dumps(payload),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def run_orchestrator_case(
    payload: object,
    *,
    mode: str,
    child_status: int = 0,
    explicit: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        scripts = root / "scripts" / "device-lab"
        scripts.mkdir(parents=True)
        shutil.copy2(ORCHESTRATOR, scripts / ORCHESTRATOR.name)
        shutil.copy2(RESOLVER, scripts / RESOLVER.name)
        # The orchestrator verifies both platform resolvers before dispatching
        # any target. Keep the Android side inert in this iOS-focused fixture.
        (scripts / "resolve-physical-android.py").write_text(
            "#!/usr/bin/env python3\nraise SystemExit(78)\n",
            encoding="utf-8",
        )
        (scripts / "evidence-policy.py").write_text(
            "#!/usr/bin/env python3\nraise SystemExit(0)\n",
            encoding="utf-8",
        )
        write_executable(
            scripts / "ios-attached-smoke.sh",
            "#!/usr/bin/env bash\nexit \"${FAKE_CHILD_STATUS:-0}\"\n",
        )

        fake_bin = root / "fake-bin"
        fake_bin.mkdir()
        write_executable(fake_bin / "uname", "#!/usr/bin/env bash\necho Darwin\n")
        write_executable(
            fake_bin / "flutter",
            """#!/usr/bin/env bash
if [[ "$1" == "devices" && "$2" == "--machine" ]]; then
  printf '%s' "$FAKE_FLUTTER_DEVICES_JSON"
  exit 0
fi
exit 2
""",
        )

        evidence = root / "evidence"
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "FAKE_FLUTTER_DEVICES_JSON": json.dumps(payload),
                "FAKE_CHILD_STATUS": str(child_status),
                "SONUS_DEVICE_LAB_DIR": str(evidence),
                "SONUS_RUN_IOS_SIMULATOR": "0",
                "SONUS_RUN_IOS_DEVICE": mode,
                "SONUS_RUN_ANDROID_DEVICE": "0",
                "SONUS_RUN_FLUTTER_MACOS": "0",
            }
        )
        if explicit is not None:
            env["IOS_DEVICE_ID"] = explicit
        else:
            env.pop("IOS_DEVICE_ID", None)

        completed = subprocess.run(
            ["bash", str(scripts / ORCHESTRATOR.name)],
            cwd=root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=20,
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
    assert 'IOS_RESOLVER="$ROOT/scripts/device-lab/resolve-physical-ios.py"' in source
    assert "physical_ios_visible" not in source

    selector = function_body(source, "select_physical_ios")
    assert "flutter devices --machine" in selector
    assert 'resolver_args+=(--device-id "$IOS_DEVICE_ID")' in selector
    assert 'python3 "$IOS_RESOLVER" "${resolver_args[@]}"' in selector

    runner = function_body(source, "run_target")
    assert 'required="${SONUS_TARGET_REQUIRED:-0}"' in runner
    assert '"$status" == "78"' in runner
    assert '"$required" != "1"' in runner
    assert '"$required" == "1"' in runner
    assert 'record_status "$name" failed' in runner

    assert "SONUS_TARGET_REQUIRED=1 run_target ios-device" in source
    assert '"$ROOT/scripts/device-lab/ios-attached-smoke.sh" "$ios_device_id"' in source

    required_case = re.search(
        r"(?ms)^  1\|true\|yes\)\n(?P<body>.*?)^    ;;$",
        source[source.index('case "$RUN_IOS_DEVICE" in'):],
    )
    assert required_case
    required_body = required_case.group("body")
    assert 'ios_device_id="$(select_physical_ios)"' in required_body
    assert "record_status ios-device failed" in required_body
    assert '"$ROOT/scripts/device-lab/ios-attached-smoke.sh" "$ios_device_id"' in required_body
    assert "record_status ios-device skipped" not in required_body

    auto_case = re.search(
        r"(?ms)^  auto\)\n(?P<body>.*?)^    ;;$",
        source[source.index('case "$RUN_IOS_DEVICE" in'):],
    )
    assert auto_case
    auto_body = auto_case.group("body")
    assert '"$selection_status" == "78"' in auto_body
    assert "record_status ios-device skipped" in auto_body
    assert "Physical iOS target selection was ambiguous or unsafe." in auto_body
    assert "record_status ios-device failed" in auto_body
    assert '"$ROOT/scripts/device-lab/ios-attached-smoke.sh" "$ios_device_id"' in auto_body

    assert "physical_ios_preselected=true" in source
    assert "required_target_exit_78_is_failure=true" in source


def assert_no_identifier_leak(result: subprocess.CompletedProcess[str], ids: list[str]) -> None:
    for device_id in ids:
        assert device_id not in result.stderr


def main() -> None:
    subprocess.run([sys.executable, "-m", "py_compile", str(RESOLVER)], check=True)
    subprocess.run([sys.executable, str(RESOLVER), "--self-test"], check=True)
    subprocess.run(["bash", "-n", str(ORCHESTRATOR)], check=True)

    iphone = device("iphone-1")
    iphone_two = device("iphone-2")
    simulator = device("sim-1", emulator=True)
    android = device("android-1", platform="android", target="android-arm64")
    unsupported = device("iphone-old", supported=False)

    cases = [
        ([iphone], None, 0, "iphone-1"),
        ([simulator, android, iphone], None, 0, "iphone-1"),
        ([iphone, iphone.copy()], None, 0, "iphone-1"),
        ([device("iphone-string", emulator="false")], None, 0, "iphone-string"),
        ([], None, EXIT_NO_TARGET, ""),
        ([iphone, iphone_two], None, EXIT_UNSAFE_SELECTION, ""),
        ([iphone], "iphone-1", 0, "iphone-1"),
        ([iphone], "stale-id", EXIT_UNSAFE_SELECTION, ""),
        ([simulator], "sim-1", EXIT_UNSAFE_SELECTION, ""),
        ([android], "android-1", EXIT_UNSAFE_SELECTION, ""),
        ([unsupported], "iphone-old", EXIT_UNSAFE_SELECTION, ""),
        ({"devices": [iphone]}, None, EXIT_UNSAFE_SELECTION, ""),
    ]

    known_ids = ["iphone-1", "iphone-2", "sim-1", "android-1", "iphone-old", "stale-id"]
    for payload, explicit, expected_code, expected_stdout in cases:
        result = run_resolver(payload, explicit)
        assert result.returncode == expected_code, (result.returncode, result.stderr)
        assert result.stdout.strip() == expected_stdout
        assert_no_identifier_leak(result, known_ids)

    malformed = subprocess.run(
        [sys.executable, str(RESOLVER)],
        input="not-json",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    assert malformed.returncode == EXIT_UNSAFE_SELECTION
    assert malformed.stdout == ""
    assert "malformed" in malformed.stderr.lower()

    # Execute the complete shell orchestrator with fake discovery and child
    # commands. These cases prove exit-78 semantics rather than only matching
    # source text.
    completed, results = run_orchestrator_case([iphone], mode="1", child_status=0)
    assert completed.returncode == 0, completed.stderr
    assert results["ios-device"] == "passed"

    completed, results = run_orchestrator_case([iphone], mode="1", child_status=78)
    assert completed.returncode == 1
    assert results["ios-device"] == "failed"
    assert "required" in (completed.stdout + completed.stderr).lower()

    completed, results = run_orchestrator_case([], mode="auto")
    assert completed.returncode == 0
    assert results["ios-device"] == "skipped"

    completed, results = run_orchestrator_case([iphone, iphone_two], mode="auto")
    assert completed.returncode == 1
    assert results["ios-device"] == "failed"

    completed, results = run_orchestrator_case([simulator], mode="1", explicit="sim-1")
    assert completed.returncode == 1
    assert results["ios-device"] == "failed"

    for completed in (
        run_orchestrator_case([iphone], mode="1", child_status=0)[0],
        run_orchestrator_case([iphone], mode="1", child_status=78)[0],
        run_orchestrator_case([iphone, iphone_two], mode="auto")[0],
    ):
        assert_no_identifier_leak(completed, known_ids)

    source = ORCHESTRATOR.read_text(encoding="utf-8")
    validate_orchestrator(source)

    mutations = (
        source.replace("SONUS_TARGET_REQUIRED=1 run_target ios-device", "run_target ios-device", 1),
        source.replace('"$required" != "1"', '"$required" == "1"', 1),
        source.replace('"$ROOT/scripts/device-lab/ios-attached-smoke.sh" "$ios_device_id"', '"$ROOT/scripts/device-lab/ios-attached-smoke.sh"', 1),
        source.replace("record_status ios-device failed", "record_status ios-device skipped", 1),
    )
    for mutated in mutations:
        try:
            validate_orchestrator(mutated)
        except AssertionError:
            pass
        else:
            raise AssertionError("unsafe orchestrator mutation unexpectedly passed")

    print(
        "physical iOS target-resolution contract passed: 12 resolver cases + "
        "malformed JSON + 5 executable orchestration cases + 4 mutation refusals"
    )


if __name__ == "__main__":
    main()
