#!/usr/bin/env python3
"""Publish signed desktop installers to an S3-compatible Cloudflare R2 bucket.

Versioned objects are immutable. Stable /latest aliases and the release manifest
are explicitly no-store so a CDN cannot pin an older installer after promotion.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9][A-Za-z0-9.-]*)?$")
BUCKET_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
EXPECTED = {
    "windows": "sonus-auris-windows-x64.exe",
    "macos": "sonus-auris-macos-universal.dmg",
    "linux": "sonus-auris-linux-x86_64.deb",
}
CONTENT_TYPES = {
    ".exe": "application/vnd.microsoft.portable-executable",
    ".dmg": "application/x-apple-diskimage",
    ".deb": "application/vnd.debian.binary-package",
    ".json": "application/json",
    ".txt": "text/plain; charset=utf-8",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    parser.add_argument("--bucket", default=os.environ.get("R2_BUCKET", ""))
    parser.add_argument("--endpoint-url", default=os.environ.get("R2_ENDPOINT_URL", ""))
    parser.add_argument("--public-base-url", default=os.environ.get("R2_PUBLIC_BASE_URL", ""))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def content_type(path: Path) -> str:
    return CONTENT_TYPES.get(path.suffix.lower()) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


def validate(args: argparse.Namespace) -> dict[str, Path]:
    if not VERSION_RE.fullmatch(args.version):
        raise ValueError("version must be SemVer-like, for example 1.2.3 or 1.2.3-rc.1")
    if not BUCKET_RE.fullmatch(args.bucket):
        raise ValueError("R2 bucket name is missing or invalid")
    endpoint = urlparse(args.endpoint_url)
    if endpoint.scheme != "https" or not endpoint.netloc or endpoint.username or endpoint.password:
        raise ValueError("R2 endpoint must be an HTTPS URL without userinfo")
    public = urlparse(args.public_base_url)
    if public.scheme != "https" or not public.netloc or public.username or public.password:
        raise ValueError("R2 public base URL must be HTTPS without userinfo")
    artifacts = {platform: args.dist / filename for platform, filename in EXPECTED.items()}
    missing = [str(path) for path in artifacts.values() if not path.is_file() or path.stat().st_size <= 0]
    if missing:
        raise ValueError("missing or empty desktop artifacts: " + ", ".join(missing))
    return artifacts


def main() -> int:
    args = parse_args()
    try:
        artifacts = validate(args)
        public_base = args.public_base_url.rstrip("/")
        published_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        checksums: list[str] = []
        manifest_artifacts: dict[str, Any] = {}

        for platform, path in artifacts.items():
            digest = sha256(path)
            versioned_key = f"releases/{args.version}/{path.name}"
            latest_key = f"latest/{path.name}"
            checksums.append(f"{digest}  {path.name}")
            manifest_artifacts[platform] = {
                "filename": path.name,
                "bytes": path.stat().st_size,
                "sha256": digest,
                "versionedKey": versioned_key,
                "url": f"{public_base}/{latest_key}",
            }

        args.dist.mkdir(parents=True, exist_ok=True)
        checksums_path = args.dist / "SHA256SUMS"
        checksums_path.write_text("\n".join(checksums) + "\n", encoding="utf-8")
        manifest_path = args.dist / "latest.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "version": args.version,
                    "publishedAt": published_at,
                    "artifacts": manifest_artifacts,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )

        plan = {
            "version": args.version,
            "bucket": args.bucket,
            "endpoint": args.endpoint_url,
            "objects": [
                *(f"releases/{args.version}/{path.name}" for path in artifacts.values()),
                *(f"latest/{path.name}" for path in artifacts.values()),
                f"releases/{args.version}/SHA256SUMS",
                "latest/SHA256SUMS",
                f"releases/{args.version}/latest.json",
                "latest.json",
            ],
        }
        if args.dry_run:
            print(json.dumps({"ok": True, "dryRun": True, **plan}, indent=2, sort_keys=True))
            return 0

        if not os.environ.get("AWS_ACCESS_KEY_ID") or not os.environ.get("AWS_SECRET_ACCESS_KEY"):
            raise ValueError("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required for R2")

        import boto3  # type: ignore[import-not-found]
        from botocore.config import Config  # type: ignore[import-not-found]

        s3 = boto3.client(
            "s3",
            endpoint_url=args.endpoint_url,
            region_name="auto",
            config=Config(
                retries={"max_attempts": 4, "mode": "standard"},
                connect_timeout=10,
                read_timeout=120,
                signature_version="s3v4",
            ),
        )

        immutable_cache = "public, max-age=31536000, immutable"
        latest_cache = "no-store, max-age=0"
        for path in artifacts.values():
            digest = sha256(path)
            common = {
                "ContentType": content_type(path),
                "Metadata": {"version": args.version, "sha256": digest},
            }
            s3.upload_file(
                str(path),
                args.bucket,
                f"releases/{args.version}/{path.name}",
                ExtraArgs={**common, "CacheControl": immutable_cache},
            )
            s3.upload_file(
                str(path),
                args.bucket,
                f"latest/{path.name}",
                ExtraArgs={**common, "CacheControl": latest_cache},
            )

        for path, versioned_name, latest_name in (
            (checksums_path, "SHA256SUMS", "latest/SHA256SUMS"),
            (manifest_path, "latest.json", "latest.json"),
        ):
            versioned_key = f"releases/{args.version}/{versioned_name}"
            metadata = {"version": args.version, "sha256": sha256(path)}
            s3.upload_file(
                str(path),
                args.bucket,
                versioned_key,
                ExtraArgs={
                    "ContentType": content_type(path),
                    "CacheControl": immutable_cache,
                    "Metadata": metadata,
                },
            )
            s3.upload_file(
                str(path),
                args.bucket,
                latest_name,
                ExtraArgs={
                    "ContentType": content_type(path),
                    "CacheControl": latest_cache,
                    "Metadata": metadata,
                },
            )

        print(json.dumps({"ok": True, **plan}, indent=2, sort_keys=True))
        return 0
    except Exception as exc:  # noqa: BLE001 - command boundary
        print(f"publish_desktop_r2: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
