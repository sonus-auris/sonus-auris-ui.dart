#!/usr/bin/env python3
"""Upload an Android App Bundle through the Google Play Developer API.

The app record and Play Console permissions must already exist. The script opens
one edit, uploads one AAB, updates exactly one track, and commits only after every
prior request succeeds. Service-account JSON is read from an environment variable
or file and is never printed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import quote

ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API_ROOT = "https://androidpublisher.googleapis.com/androidpublisher/v3"
UPLOAD_ROOT = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"
PACKAGE_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$")
TRACK_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
ALLOWED_STATUSES = {"draft", "inProgress", "halted", "completed"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-name", required=True)
    parser.add_argument("--aab", type=Path, required=True)
    parser.add_argument("--track", default="internal")
    parser.add_argument("--status", default="completed", choices=sorted(ALLOWED_STATUSES))
    parser.add_argument("--release-name", default="")
    parser.add_argument("--service-account-file", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def validate(args: argparse.Namespace) -> None:
    if not PACKAGE_RE.fullmatch(args.package_name):
        raise ValueError("invalid Android package name")
    if not TRACK_RE.fullmatch(args.track):
        raise ValueError("invalid Play track name")
    if not args.aab.is_file():
        raise ValueError(f"AAB does not exist: {args.aab}")
    if args.aab.suffix.lower() != ".aab":
        raise ValueError("bundle path must end in .aab")
    if args.aab.stat().st_size <= 0:
        raise ValueError("AAB is empty")
    if len(args.release_name) > 200:
        raise ValueError("release name exceeds 200 characters")


def load_service_account(args: argparse.Namespace) -> dict[str, Any]:
    if args.service_account_file:
        raw = args.service_account_file.read_text(encoding="utf-8")
    else:
        raw = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON", "")
    if not raw.strip():
        raise ValueError(
            "set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON or pass --service-account-file"
        )
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("type") != "service_account":
        raise ValueError("Google Play credentials are not service-account JSON")
    for field in ("client_email", "private_key", "token_uri"):
        if not isinstance(value.get(field), str) or not value[field].strip():
            raise ValueError(f"service-account JSON is missing {field}")
    return value


def error_excerpt(response: Any) -> str:
    text = response.text or ""
    text = text.replace("\r", " ").replace("\n", " ")
    return text[:4096]


def require_success(response: Any, operation: str) -> Any:
    if not response.ok:
        raise RuntimeError(
            f"{operation} failed with HTTP {response.status_code}: {error_excerpt(response)}"
        )
    if not response.content:
        return {}
    return response.json()


def main() -> int:
    args = parse_args()
    try:
        validate(args)
        if args.dry_run:
            print(
                json.dumps(
                    {
                        "ok": True,
                        "dryRun": True,
                        "packageName": args.package_name,
                        "track": args.track,
                        "status": args.status,
                        "aabBytes": args.aab.stat().st_size,
                    },
                    sort_keys=True,
                )
            )
            return 0

        service_account_info = load_service_account(args)

        # Imported only for a live publication. CI can exercise --dry-run without
        # installing network/auth dependencies.
        import requests  # type: ignore[import-not-found]
        from google.auth.transport.requests import Request  # type: ignore[import-not-found]
        from google.oauth2 import service_account  # type: ignore[import-not-found]

        credentials = service_account.Credentials.from_service_account_info(
            service_account_info,
            scopes=[ANDROID_PUBLISHER_SCOPE],
        )
        credentials.refresh(Request())
        if not credentials.token:
            raise RuntimeError("Google service account did not produce an access token")

        session = requests.Session()
        session.headers.update(
            {
                "Authorization": f"Bearer {credentials.token}",
                "Accept": "application/json",
                "User-Agent": "sonus-auris-release/1",
            }
        )

        package = quote(args.package_name, safe="")
        edit = require_success(
            session.post(
                f"{API_ROOT}/applications/{package}/edits",
                json={},
                timeout=30,
                allow_redirects=False,
            ),
            "create Play edit",
        )
        edit_id = edit.get("id")
        if not isinstance(edit_id, str) or not edit_id:
            raise RuntimeError("Play edit response did not contain an id")

        with args.aab.open("rb") as bundle:
            uploaded = require_success(
                session.post(
                    f"{UPLOAD_ROOT}/applications/{package}/edits/{quote(edit_id, safe='')}/bundles",
                    params={"uploadType": "media"},
                    data=bundle,
                    headers={"Content-Type": "application/octet-stream"},
                    timeout=600,
                    allow_redirects=False,
                ),
                "upload AAB",
            )
        version_code = uploaded.get("versionCode")
        if not isinstance(version_code, int) or version_code <= 0:
            raise RuntimeError("bundle upload response did not contain a valid versionCode")

        release: dict[str, Any] = {
            "versionCodes": [str(version_code)],
            "status": args.status,
        }
        if args.release_name:
            release["name"] = args.release_name

        require_success(
            session.put(
                f"{API_ROOT}/applications/{package}/edits/{quote(edit_id, safe='')}/tracks/{quote(args.track, safe='')}",
                json={"track": args.track, "releases": [release]},
                timeout=30,
                allow_redirects=False,
            ),
            "update Play track",
        )
        committed = require_success(
            session.post(
                f"{API_ROOT}/applications/{package}/edits/{quote(edit_id, safe='')}:commit",
                json={},
                timeout=30,
                allow_redirects=False,
            ),
            "commit Play edit",
        )
        print(
            json.dumps(
                {
                    "ok": True,
                    "packageName": args.package_name,
                    "track": args.track,
                    "status": args.status,
                    "versionCode": version_code,
                    "editId": committed.get("id", edit_id),
                },
                sort_keys=True,
            )
        )
        return 0
    except Exception as exc:  # noqa: BLE001 - command boundary
        print(f"publish_google_play: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
