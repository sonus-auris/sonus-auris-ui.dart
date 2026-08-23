#!/usr/bin/env python3
"""Audit a Sonus Auris device-lab ZIP without extracting it.

The auditor verifies ZIP path safety, rejects symlinks and raw/key material,
scans UTF-8 evidence with the shared evidence policy, reports fatal log markers,
parses simple result files, and records PNG dimensions/digests. Entry and
aggregate expansion are bounded before any archive member is read.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import stat
import struct
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MAX_ENTRY_BYTES = 20 * 1024 * 1024
MAX_TOTAL_BYTES = 200 * 1024 * 1024
MAX_TEXT_BYTES = 5 * 1024 * 1024
MAX_COMPRESSION_RATIO = 250
FATAL_PATTERNS = (
    re.compile(r"Terminating app due to uncaught exception", re.I),
    re.compile(r"\bFatal error\b", re.I),
    re.compile(r"\bFATAL EXCEPTION\b"),
    re.compile(r"\bEXC_CRASH\b"),
    re.compile(r"\bSIGABRT\b"),
    re.compile(r"\bsegmentation fault\b", re.I),
    re.compile(r"\bpanicked at\b"),
    re.compile(r"\bLost connection to device\b", re.I),
    re.compile(r"Library not loaded", re.I),
)


def load_policy() -> Any:
    path = Path(__file__).with_name("evidence-policy.py")
    spec = importlib.util.spec_from_file_location("sonus_evidence_policy", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load evidence policy: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_member_name(name: str) -> tuple[bool, str | None]:
    if "\\" in name:
        return False, "backslash path separator"
    candidate = PurePosixPath(name)
    if candidate.is_absolute():
        return False, "absolute path"
    if any(part in ("", ".", "..") for part in candidate.parts):
        return False, "empty/dot/traversal component"
    return True, None


def is_symlink(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0xFFFF
    return stat.S_IFMT(mode) == stat.S_IFLNK


def png_dimensions(data: bytes) -> list[int] | None:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return [width, height]


def parse_key_value(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in text.splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        key = key.strip()
        if key and re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            result[key] = value.strip()
    return result


def audit_zip(path: Path, expected_sha256: str | None = None) -> dict[str, Any]:
    policy = load_policy()
    archive_sha256 = sha256_file(path)
    findings: list[str] = []
    if expected_sha256 and archive_sha256.lower() != expected_sha256.lower():
        findings.append("archive sha256 does not match expected digest")

    report: dict[str, Any] = {
        "schema": "sonus-auris-device-lab-artifact-audit/v1",
        "archive": path.name,
        "sha256": archive_sha256,
        "expected_sha256": expected_sha256,
        "entries": 0,
        "uncompressed_bytes": 0,
        "path_violations": [],
        "symlinks": [],
        "forbidden_artifacts": [],
        "oversized_entries": [],
        "suspicious_compression": [],
        "text_files_scanned": 0,
        "privacy_violations": {},
        "fatal_log_matches": {},
        "line_counts": {},
        "legacy_tail_cap_suspected": [],
        "pngs": {},
        "identical_png_groups": [],
        "key_value_files": {},
        "json_summaries": {},
        "findings": findings,
    }

    png_hash_to_names: dict[str, list[str]] = {}
    total_uncompressed = 0
    with zipfile.ZipFile(path) as archive:
        infos = archive.infolist()
        report["entries"] = len(infos)
        for info in infos:
            name = info.filename
            total_uncompressed += info.file_size
            okay, reason = safe_member_name(name)
            if not okay:
                report["path_violations"].append({"name": name, "reason": reason})
                continue
            if is_symlink(info):
                report["symlinks"].append(name)
                continue
            if info.is_dir():
                continue
            if info.file_size > MAX_ENTRY_BYTES:
                report["oversized_entries"].append(
                    {"name": name, "bytes": info.file_size}
                )
                continue
            if (
                info.compress_size > 0
                and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO
            ):
                report["suspicious_compression"].append(
                    {"name": name, "ratio": round(info.file_size / info.compress_size, 2)}
                )
            suffix = PurePosixPath(name).suffix.lower()
            if suffix in policy.SENSITIVE_SUFFIXES:
                report["forbidden_artifacts"].append(name)
                continue
            data = archive.read(info)
            if suffix == ".png":
                digest = hashlib.sha256(data).hexdigest()
                report["pngs"][name] = {
                    "bytes": len(data),
                    "sha256": digest,
                    "dimensions": png_dimensions(data),
                }
                png_hash_to_names.setdefault(digest, []).append(name)
            if len(data) > MAX_TEXT_BYTES or b"\x00" in data[:8192]:
                continue
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            report["text_files_scanned"] += 1
            privacy = sorted(policy.remaining_violations(text))
            if privacy:
                report["privacy_violations"][name] = privacy
            fatal = sorted(
                {pattern.pattern for pattern in FATAL_PATTERNS if pattern.search(text)}
            )
            if fatal:
                report["fatal_log_matches"][name] = fatal
            line_count = len(text.splitlines())
            report["line_counts"][name] = line_count
            if name.endswith(".log") and line_count == 500:
                report["legacy_tail_cap_suspected"].append(name)
            key_values = parse_key_value(text)
            if key_values:
                report["key_value_files"][name] = key_values
            if suffix == ".json":
                try:
                    payload = json.loads(text)
                except json.JSONDecodeError:
                    report["json_summaries"][name] = {"valid_json": False}
                else:
                    summary: dict[str, Any] = {"valid_json": True}
                    if isinstance(payload, dict):
                        for key in (
                            "schema",
                            "platform",
                            "device_count",
                            "recording_requested",
                            "enumeration_error",
                        ):
                            if key in payload:
                                summary[key] = payload[key]
                        devices = payload.get("devices")
                        if isinstance(devices, list):
                            summary["device_rows"] = len(devices)
                            summary["raw_name_keys_present"] = any(
                                isinstance(row, dict) and "name" in row for row in devices
                            )
                    report["json_summaries"][name] = summary

    report["uncompressed_bytes"] = total_uncompressed
    if total_uncompressed > MAX_TOTAL_BYTES:
        findings.append("archive exceeds aggregate uncompressed byte limit")
    report["identical_png_groups"] = [
        names for names in png_hash_to_names.values() if len(names) > 1
    ]

    for key in (
        "path_violations",
        "symlinks",
        "forbidden_artifacts",
        "oversized_entries",
        "suspicious_compression",
    ):
        if report[key]:
            findings.append(f"{key}: {len(report[key])}")
    if report["privacy_violations"]:
        findings.append(
            f"privacy_violations: {len(report['privacy_violations'])} files"
        )
    if report["fatal_log_matches"]:
        findings.append(f"fatal_log_matches: {len(report['fatal_log_matches'])} files")
    if report["legacy_tail_cap_suspected"]:
        findings.append(
            "legacy_tail_cap_suspected: "
            f"{len(report['legacy_tail_cap_suspected'])} logs"
        )
    report["status"] = "passed" if not findings else "attention-required"
    return report


def write_zip(path: Path, entries: dict[str, bytes], symlink: str | None = None) -> None:
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
        if symlink:
            info = zipfile.ZipInfo(symlink)
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, "target.txt")


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="sonus-artifact-audit-") as temp:
        root = Path(temp)
        safe = root / "safe.zip"
        write_zip(
            safe,
            {
                "result.txt": b"status=passed\n",
                "AppIcon60x60@2x.png.txt": b"safe\n",
            },
        )
        safe_report = audit_zip(safe)
        assert safe_report["status"] == "passed", safe_report

        cases = {
            "traversal": ({"../escape.txt": b"x"}, None, "path_violations"),
            "audio": ({"raw.wav": b"RIFF"}, None, "forbidden_artifacts"),
            "secret": (
                {"run.log": b"access_token=SYNTHETIC_SECRET\n"},
                None,
                "privacy_violations",
            ),
            "symlink": ({"target.txt": b"safe"}, "link.txt", "symlinks"),
            "legacy-tail": (
                {"simulator.log": (b"line\n" * 500)},
                None,
                "legacy_tail_cap_suspected",
            ),
        }
        for name, (entries, link, expected_key) in cases.items():
            artifact = root / f"{name}.zip"
            write_zip(artifact, entries, link)
            report = audit_zip(artifact)
            assert report[expected_key], (name, report)
            assert report["status"] == "attention-required", (name, report)

        mismatch = audit_zip(safe, expected_sha256="0" * 64)
        assert "archive sha256 does not match expected digest" in mismatch["findings"]
    print("Sonus Auris artifact audit self-test passed: 7 cases")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", nargs="?", type=Path)
    parser.add_argument("--expected-sha256")
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.archive is None:
        parser.error("archive is required unless --self-test is used")
    report = audit_zip(args.archive, args.expected_sha256)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    if args.strict and report["status"] != "passed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
