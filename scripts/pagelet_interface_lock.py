#!/usr/bin/env python3
"""Validate the immutable Sonus Auris interface dependency used by Flutter CI."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

INTERFACE_REPOSITORY = "sonus-auris/sonus-auris-interfaces"
LOCK_KEYS = {"schemaVersion", "repository", "commitSha"}
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")


def fail(message: str) -> "NoReturn":
    raise SystemExit(message)


def read_regular_json(path: Path, label: str) -> dict[str, Any]:
    absolute = path.absolute()
    try:
        stat = absolute.lstat()
    except OSError as exc:
        fail(f"failed to inspect {label} {path}: {exc}")
    if absolute.is_symlink() or not stat.st_mode:
        fail(f"{label} must be a regular, non-symlink file")
    try:
        if not absolute.is_file() or absolute.resolve(strict=True) != absolute:
            fail(f"{label} must be a regular file without symlinked path components")
        value = json.loads(absolute.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"failed to read {label} {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must contain a JSON object")
    return value


def validate_lock(value: dict[str, Any]) -> dict[str, Any]:
    actual_keys = set(value)
    if actual_keys != LOCK_KEYS:
        fail(
            "interface lock keys drifted: "
            f"expected={sorted(LOCK_KEYS)}, actual={sorted(actual_keys)}"
        )
    if value["schemaVersion"] != 1:
        fail("interface lock schemaVersion must equal 1")
    if value["repository"] != INTERFACE_REPOSITORY:
        fail(f"interface lock repository must equal {INTERFACE_REPOSITORY}")
    commit = value["commitSha"]
    if not isinstance(commit, str) or not GIT_SHA.fullmatch(commit):
        fail("interface lock commitSha must be a full lowercase 40-character SHA")
    return {
        "schemaVersion": 1,
        "repository": INTERFACE_REPOSITORY,
        "commitSha": commit,
    }


def load_lock(path: Path) -> dict[str, Any]:
    return validate_lock(read_regular_json(path, "interface lock"))


def append_github_outputs(path: Path, lock: dict[str, Any]) -> None:
    try:
        with path.open("a", encoding="utf-8", newline="\n") as output:
            output.write(f"repository={lock['repository']}\n")
            output.write(f"commit={lock['commitSha']}\n")
    except OSError as exc:
        fail(f"failed to write GitHub outputs: {exc}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    lock = load_lock(args.lock)
    if args.github_output is not None:
        append_github_outputs(args.github_output, lock)
    print(json.dumps(lock, sort_keys=True))


if __name__ == "__main__":
    main()
