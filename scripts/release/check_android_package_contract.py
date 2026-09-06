#!/usr/bin/env python3
"""Fail closed when Gradle and the Android publication workflow disagree."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")
GRADLE_ID_RE = re.compile(
    r'^\s*val\s+productionApplicationId\s*=\s*"([^"]+)"\s*$',
    re.MULTILINE,
)
WORKFLOW_ID_RE = re.compile(
    r"^\s*SONUS_ANDROID_APPLICATION_ID:\s*([A-Za-z][A-Za-z0-9_.]*)\s*$",
    re.MULTILINE,
)
PACKAGE_ARGUMENT = '--package-name "$SONUS_ANDROID_APPLICATION_ID"'
LEGACY_PACKAGE_IDS = {"com.ores.audio_dashcam"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected", required=True)
    parser.add_argument(
        "--gradle",
        type=Path,
        default=Path("android/app/build.gradle.kts"),
    )
    parser.add_argument(
        "--workflow",
        type=Path,
        default=Path(".github/workflows/android-release.yml"),
    )
    parser.add_argument(
        "--print-application-id",
        action="store_true",
        help="Print only the validated application ID.",
    )
    return parser.parse_args()


def one_match(pattern: re.Pattern[str], text: str, label: str) -> str:
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise ValueError(f"{label} must have exactly one declaration; found {len(matches)}")
    return matches[0]


def main() -> int:
    args = parse_args()
    try:
        expected = args.expected.strip()
        if not PACKAGE_RE.fullmatch(expected):
            raise ValueError("expected package name is invalid")

        gradle_text = args.gradle.read_text(encoding="utf-8")
        workflow_text = args.workflow.read_text(encoding="utf-8")

        gradle_id = one_match(GRADLE_ID_RE, gradle_text, "Gradle productionApplicationId")
        workflow_id = one_match(
            WORKFLOW_ID_RE,
            workflow_text,
            "workflow SONUS_ANDROID_APPLICATION_ID",
        )

        if gradle_id != expected:
            raise ValueError(
                f"Gradle application ID {gradle_id!r} differs from expected {expected!r}"
            )
        if workflow_id != expected:
            raise ValueError(
                f"workflow application ID {workflow_id!r} differs from expected {expected!r}"
            )

        legacy_hits = sorted(
            package_id
            for package_id in LEGACY_PACKAGE_IDS
            if package_id in gradle_text or package_id in workflow_text
        )
        if legacy_hits:
            raise ValueError(
                "legacy Android package ID remains in the release contract: "
                + ", ".join(legacy_hits)
            )

        argument_count = workflow_text.count(PACKAGE_ARGUMENT)
        if argument_count != 2:
            raise ValueError(
                "dry-run and live Play publication must both use "
                f"{PACKAGE_ARGUMENT!r}; found {argument_count} occurrence(s)"
            )

        direct_package_args = re.findall(
            r'--package-name\s+(?!"\$SONUS_ANDROID_APPLICATION_ID")[^\s]+',
            workflow_text,
        )
        if direct_package_args:
            raise ValueError(
                "release workflow contains a direct package-name argument: "
                + ", ".join(direct_package_args)
            )

        if args.print_application_id:
            print(expected)
        else:
            print(
                json.dumps(
                    {
                        "ok": True,
                        "applicationId": expected,
                        "gradle": str(args.gradle),
                        "workflow": str(args.workflow),
                        "playPublicationCalls": argument_count,
                    },
                    sort_keys=True,
                )
            )
        return 0
    except Exception as exc:  # noqa: BLE001 - command boundary
        print(f"check_android_package_contract: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
