#!/usr/bin/env python3
"""Select one eligible physical iOS target from `flutter devices --machine`.

Exit codes are part of the device-lab contract:

* 0: exactly one eligible target selected (ID written to stdout)
* 78: no eligible physical iOS target is currently visible
* 79: ambiguous, malformed, stale, or non-physical explicit selection

Diagnostics never include raw device IDs or user-visible device names.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable
from typing import Any, TextIO

EXIT_NO_TARGET = 78
EXIT_UNSAFE_SELECTION = 79


def is_ios_target(device: dict[str, Any]) -> bool:
    target = str(device.get("targetPlatform", "")).lower()
    platform = str(device.get("platform", "")).lower()
    return target.startswith("ios") or platform.startswith("ios")


def bool_value(value: object, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes"}:
            return True
        if normalized in {"false", "0", "no", ""}:
            return False
    return default


def is_emulator(device: dict[str, Any]) -> bool:
    return bool_value(device.get("emulator", device.get("isEmulator")), False)


def is_supported(device: dict[str, Any]) -> bool:
    # Older Flutter versions omit this field. Explicit false is authoritative;
    # absence remains eligible for compatibility.
    return bool_value(device.get("isSupported"), True)


def eligible_devices(payload: object) -> list[dict[str, Any]]:
    if not isinstance(payload, list):
        raise ValueError("Flutter device discovery did not return a list")

    by_id: dict[str, dict[str, Any]] = {}
    for item in payload:
        if not isinstance(item, dict):
            continue
        device_id = str(item.get("id", "")).strip()
        if not device_id:
            continue
        if is_emulator(item) or not is_ios_target(item) or not is_supported(item):
            continue
        by_id.setdefault(device_id, item)
    return list(by_id.values())


def resolve(payload: object, explicit_id: str | None) -> tuple[int, str | None, str | None]:
    try:
        devices = eligible_devices(payload)
    except ValueError:
        return EXIT_UNSAFE_SELECTION, None, "Flutter device discovery was malformed."

    if explicit_id:
        for device in devices:
            if str(device.get("id", "")) == explicit_id:
                return 0, explicit_id, None
        return (
            EXIT_UNSAFE_SELECTION,
            None,
            "The explicit iOS target is stale, unsupported, simulated, or not an iPhone/iPad device.",
        )

    if not devices:
        return EXIT_NO_TARGET, None, "No eligible paired physical iOS target is visible."
    if len(devices) > 1:
        return (
            EXIT_UNSAFE_SELECTION,
            None,
            "Multiple eligible physical iOS targets are visible; select one explicitly.",
        )
    return 0, str(devices[0]["id"]), None


def load_payload(stream: TextIO) -> object:
    try:
        return json.load(stream)
    except Exception as error:
        raise ValueError("Flutter device discovery was malformed") from error


def self_test() -> None:
    physical = {
        "id": "iphone-1",
        "emulator": False,
        "targetPlatform": "ios",
        "platform": "ios",
    }
    simulator = {
        "id": "sim-1",
        "emulator": True,
        "targetPlatform": "ios",
        "platform": "ios",
    }
    android = {
        "id": "android-1",
        "emulator": False,
        "targetPlatform": "android-arm64",
        "platform": "android",
    }
    unsupported = {**physical, "id": "iphone-old", "isSupported": False}
    string_boolean_physical = {**physical, "id": "iphone-string", "emulator": "false"}

    assert resolve([physical], None)[:2] == (0, "iphone-1")
    assert resolve([simulator, physical, android], None)[:2] == (0, "iphone-1")
    assert resolve([], None)[0] == EXIT_NO_TARGET
    assert resolve([physical, {**physical, "id": "iphone-2"}], None)[0] == EXIT_UNSAFE_SELECTION
    assert resolve([physical, physical.copy()], None)[:2] == (0, "iphone-1")
    assert resolve([physical], "iphone-1")[:2] == (0, "iphone-1")
    assert resolve([simulator], "sim-1")[0] == EXIT_UNSAFE_SELECTION
    assert resolve([android], "android-1")[0] == EXIT_UNSAFE_SELECTION
    assert resolve([unsupported], "iphone-old")[0] == EXIT_UNSAFE_SELECTION
    assert resolve([string_boolean_physical], None)[:2] == (0, "iphone-string")
    assert resolve({"devices": [physical]}, None)[0] == EXIT_UNSAFE_SELECTION

    print(
        "physical iOS resolver self-test passed: unique + mixed + none + "
        "ambiguous + duplicate + stale/simulator/Android/unsupported refusal"
    )


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device-id")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    try:
        payload = load_payload(sys.stdin)
    except ValueError:
        print("Flutter device discovery was malformed.", file=sys.stderr)
        return EXIT_UNSAFE_SELECTION

    status, device_id, message = resolve(payload, args.device_id)
    if message:
        print(message, file=sys.stderr)
    if status == 0:
        assert device_id
        print(device_id)
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
