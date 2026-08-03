#!/usr/bin/env python3
"""Select one authorized physical Android target using read-only ADB probes.

Exit codes are part of the device-lab contract:

* 0: exactly one eligible physical Android target selected (serial on stdout)
* 78: no eligible physical Android target is currently visible
* 79: ambiguous, malformed, stale, unauthorized, emulated, or unverified target

Diagnostics never include raw serials, model names, or transport identifiers.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from enum import Enum

EXIT_NO_TARGET = 78
EXIT_UNSAFE_SELECTION = 79


@dataclass(frozen=True)
class AdbTarget:
    serial: str
    state: str


class ProbeResult(Enum):
    PHYSICAL = "physical"
    EMULATOR = "emulator"
    UNVERIFIED = "unverified"


def parse_devices(output: str) -> list[AdbTarget]:
    """Parse `adb devices -l`, deduplicating identical serial rows."""

    lines = output.replace("\r", "").splitlines()
    if not lines or not lines[0].strip().startswith("List of devices attached"):
        raise ValueError("ADB discovery output was malformed")

    by_serial: dict[str, AdbTarget] = {}
    for raw in lines[1:]:
        stripped = raw.strip()
        if not stripped or stripped.startswith("*"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise ValueError("ADB discovery output was malformed")
        target = AdbTarget(serial=fields[0], state=fields[1])
        previous = by_serial.get(target.serial)
        if previous is not None and previous.state != target.state:
            raise ValueError("ADB discovery returned conflicting target states")
        by_serial.setdefault(target.serial, target)
    return list(by_serial.values())


def classify_probe(serial: str, command_status: int, output: str) -> ProbeResult:
    if serial.startswith("emulator-"):
        return ProbeResult.EMULATOR
    if command_status != 0:
        return ProbeResult.UNVERIFIED
    value = output.replace("\r", "").strip().lower()
    if value == "1" or value == "true":
        return ProbeResult.EMULATOR
    if value in {"", "0", "false"}:
        return ProbeResult.PHYSICAL
    return ProbeResult.UNVERIFIED


def resolve(
    targets: list[AdbTarget],
    explicit_serial: str | None,
    probe: Callable[[str], ProbeResult],
) -> tuple[int, str | None, str | None]:
    by_serial = {target.serial: target for target in targets}

    if explicit_serial:
        target = by_serial.get(explicit_serial)
        if target is None or target.state != "device":
            return (
                EXIT_UNSAFE_SELECTION,
                None,
                "The explicit Android target is stale, unauthorized, offline, or unavailable.",
            )
        classification = probe(target.serial)
        if classification is not ProbeResult.PHYSICAL:
            return (
                EXIT_UNSAFE_SELECTION,
                None,
                "The explicit Android target is emulated or could not be verified as physical.",
            )
        return 0, target.serial, None

    physical: list[str] = []
    unverified = False
    for target in targets:
        if target.state != "device":
            continue
        classification = probe(target.serial)
        if classification is ProbeResult.PHYSICAL:
            physical.append(target.serial)
        elif classification is ProbeResult.UNVERIFIED:
            unverified = True

    if unverified:
        return (
            EXIT_UNSAFE_SELECTION,
            None,
            "An authorized Android target could not be verified as physical.",
        )
    if not physical:
        return EXIT_NO_TARGET, None, "No authorized physical Android target is visible."
    if len(physical) > 1:
        return (
            EXIT_UNSAFE_SELECTION,
            None,
            "Multiple authorized physical Android targets are visible; select one explicitly.",
        )
    return 0, physical[0], None


def discover(adb: str) -> list[AdbTarget]:
    try:
        completed = subprocess.run(
            [adb, "devices", "-l"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("ADB discovery failed") from error
    if completed.returncode != 0:
        raise ValueError("ADB discovery failed")
    return parse_devices(completed.stdout)


def make_probe(adb: str) -> Callable[[str], ProbeResult]:
    def probe(serial: str) -> ProbeResult:
        try:
            completed = subprocess.run(
                [adb, "-s", serial, "shell", "getprop", "ro.kernel.qemu"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=8,
            )
        except (OSError, subprocess.TimeoutExpired):
            return ProbeResult.UNVERIFIED
        return classify_probe(serial, completed.returncode, completed.stdout)

    return probe


def self_test() -> None:
    physical = AdbTarget("usb-physical", "device")
    physical_two = AdbTarget("tcp-physical", "device")
    emulator = AdbTarget("emulator-5554", "device")
    tcp_emulator = AdbTarget("127.0.0.1:5555", "device")
    unauthorized = AdbTarget("usb-locked", "unauthorized")

    mapping = {
        physical.serial: ProbeResult.PHYSICAL,
        physical_two.serial: ProbeResult.PHYSICAL,
        emulator.serial: ProbeResult.EMULATOR,
        tcp_emulator.serial: ProbeResult.EMULATOR,
        unauthorized.serial: ProbeResult.UNVERIFIED,
    }
    probe = lambda serial: mapping[serial]

    assert resolve([physical], None, probe)[:2] == (0, physical.serial)
    assert resolve([emulator, tcp_emulator, physical], None, probe)[:2] == (
        0,
        physical.serial,
    )
    assert resolve([emulator, tcp_emulator], None, probe)[0] == EXIT_NO_TARGET
    assert resolve([], None, probe)[0] == EXIT_NO_TARGET
    assert resolve([physical, physical_two], None, probe)[0] == EXIT_UNSAFE_SELECTION
    assert resolve([unauthorized], None, probe)[0] == EXIT_NO_TARGET
    assert resolve([physical], physical.serial, probe)[:2] == (0, physical.serial)
    assert resolve([unauthorized], unauthorized.serial, probe)[0] == EXIT_UNSAFE_SELECTION
    assert resolve([emulator], emulator.serial, probe)[0] == EXIT_UNSAFE_SELECTION
    assert resolve([tcp_emulator], tcp_emulator.serial, probe)[0] == EXIT_UNSAFE_SELECTION
    assert classify_probe("tcp-phone", 0, "") is ProbeResult.PHYSICAL
    assert classify_probe("tcp-phone", 0, "0\r\n") is ProbeResult.PHYSICAL
    assert classify_probe("tcp-emulator", 0, "1\n") is ProbeResult.EMULATOR
    assert classify_probe("tcp-unknown", 1, "") is ProbeResult.UNVERIFIED
    assert classify_probe("tcp-unknown", 0, "unexpected") is ProbeResult.UNVERIFIED

    parsed = parse_devices(
        "List of devices attached\r\n"
        "usb-physical\tdevice product:p model:m transport_id:1\r\n"
        "usb-physical\tdevice product:p model:m transport_id:1\r\n"
    )
    assert parsed == [physical]

    print(
        "physical Android resolver self-test passed: unique + emulator exclusion + "
        "TCP qemu probe + duplicates + unauthorized + ambiguous + explicit refusal"
    )


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0

    try:
        targets = discover(args.adb)
    except ValueError:
        print("ADB target discovery was unavailable or malformed.", file=sys.stderr)
        return EXIT_UNSAFE_SELECTION

    status, serial, message = resolve(targets, args.serial, make_probe(args.adb))
    if message:
        print(message, file=sys.stderr)
    if status == 0:
        assert serial
        print(serial)
    return status


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
