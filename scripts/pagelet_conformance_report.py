#!/usr/bin/env python3
"""Generate a provenance-bound pagelet conformance coverage report.

The focused host tests must succeed before this script runs. The committed
coverage file declares which canonical scenarios those tests automate and which
remain inventory-only or not applicable. A certifiable report additionally
binds that coverage to exact interface and host source identities supplied by
the canonical interfaces repository.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any, NoReturn

ALLOWED_STATUS = {"automated", "inventory-only", "not-applicable"}
INTERFACE_REPOSITORY = "sonus-auris/sonus-auris-interfaces"
SCENARIO_PATH = "pagelets/v1/conformance-scenarios.json"
REPORT_SCHEMA_PATH = "pagelets/v1/conformance-report.schema.json"
HOST_REPOSITORIES = {
    "flutter": "sonus-auris/sonus-auris-ui.dart",
    "rust-desktop": "sonus-auris/desktop.app.rs",
}
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PROVENANCE_REQUIRED_KEYS = {
    "interfaceRepository",
    "interfaceCommitSha",
    "interfacePayloadTreeSha256",
    "interfaceBundleSchemaVersion",
    "scenarioPath",
    "scenarioSha256",
    "reportSchemaPath",
    "reportSchemaSha256",
    "hostRepository",
    "hostCommitSha",
}
PROVENANCE_OPTIONAL_KEYS = {"runUrl"}


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_regular_bytes(path: Path, label: str) -> bytes:
    absolute = path.absolute()
    try:
        metadata = absolute.lstat()
    except OSError as exc:
        fail(f"failed to inspect {label} {path}: {exc}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{label} must be a regular, non-symlink file")
    try:
        if absolute.resolve(strict=True) != absolute:
            fail(f"{label} may not resolve through a symlinked path component")
        return absolute.read_bytes()
    except OSError as exc:
        fail(f"failed to read {label} {path}: {exc}")


def parse_json_bytes(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"{label} is not valid UTF-8 JSON: {exc}")
    if not isinstance(parsed, dict):
        fail(f"{label} must contain a JSON object")
    return parsed


def read_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    raw = read_regular_bytes(path, label)
    return parse_json_bytes(raw, label), raw


def require_exact_keys(
    value: dict[str, Any],
    required: set[str],
    optional: set[str],
    label: str,
) -> None:
    actual = set(value)
    missing = sorted(required - actual)
    unknown = sorted(actual - required - optional)
    if missing or unknown:
        fail(f"{label} keys drifted: missing={missing}, unknown={unknown}")


def validate_provenance(
    value: dict[str, Any],
    *,
    host: str,
    scenario_bytes: bytes,
    report_schema_bytes: bytes,
) -> dict[str, Any]:
    require_exact_keys(
        value,
        PROVENANCE_REQUIRED_KEYS,
        PROVENANCE_OPTIONAL_KEYS,
        "provenance",
    )
    expected_host_repository = HOST_REPOSITORIES[host]
    exact_values = {
        "interfaceRepository": INTERFACE_REPOSITORY,
        "interfaceBundleSchemaVersion": 1,
        "scenarioPath": SCENARIO_PATH,
        "scenarioSha256": sha256_bytes(scenario_bytes),
        "reportSchemaPath": REPORT_SCHEMA_PATH,
        "reportSchemaSha256": sha256_bytes(report_schema_bytes),
        "hostRepository": expected_host_repository,
    }
    for field, expected in exact_values.items():
        if value.get(field) != expected:
            fail(f"provenance {field} does not match the expected interface/host input")

    for field in ("interfaceCommitSha", "hostCommitSha"):
        candidate = value.get(field)
        if not isinstance(candidate, str) or not GIT_SHA.fullmatch(candidate):
            fail(f"provenance {field} must be a full lowercase 40-character SHA")
    for field in (
        "interfacePayloadTreeSha256",
        "scenarioSha256",
        "reportSchemaSha256",
    ):
        candidate = value.get(field)
        if not isinstance(candidate, str) or not SHA256.fullmatch(candidate):
            fail(f"provenance {field} must be a full lowercase SHA-256")

    run_url = value.get("runUrl")
    if run_url is not None:
        if not isinstance(run_url, str) or len(run_url) > 300:
            fail("provenance runUrl must be a bounded string")
        escaped_repository = re.escape(expected_host_repository)
        if not re.fullmatch(
            rf"https://github\.com/{escaped_repository}/actions/runs/[1-9][0-9]*",
            run_url,
        ):
            fail("provenance runUrl must identify an Actions run in the host repository")

    return dict(value)


def validate_coverage(
    scenario_doc: dict[str, Any],
    coverage_doc: dict[str, Any],
    host: str,
) -> list[dict[str, Any]]:
    scenarios = scenario_doc.get("scenarios")
    entries = coverage_doc.get("entries")
    if scenario_doc.get("scenarioVersion") != "1.0.0":
        fail("unsupported scenarioVersion")
    if not isinstance(scenarios, list) or not scenarios:
        fail("scenario inventory must contain a non-empty scenarios array")
    if coverage_doc.get("coverageVersion") != "1.0.0":
        fail("unsupported coverageVersion")
    if coverage_doc.get("host") != host:
        fail("coverage host does not match --host")
    if not isinstance(entries, list):
        fail("coverage must contain an entries array")

    scenario_by_id: dict[str, dict[str, Any]] = {}
    for scenario in scenarios:
        if not isinstance(scenario, dict) or not isinstance(scenario.get("id"), str):
            fail("every scenario must be an object with a string id")
        scenario_id = scenario["id"]
        if scenario_id in scenario_by_id:
            fail(f"duplicate scenario id: {scenario_id}")
        scenario_by_id[scenario_id] = scenario

    coverage_by_id: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            fail("every coverage entry must be an object with a string id")
        scenario_id = entry["id"]
        if scenario_id in coverage_by_id:
            fail(f"duplicate coverage id: {scenario_id}")
        status_value = entry.get("status")
        evidence = entry.get("evidence")
        if status_value not in ALLOWED_STATUS:
            fail(f"invalid coverage status for {scenario_id}: {status_value}")
        if not isinstance(evidence, list) or not all(
            isinstance(item, str) and item and len(item) <= 240 for item in evidence
        ):
            fail(f"coverage evidence for {scenario_id} must be a bounded string array")
        if len(evidence) > 12:
            fail(f"coverage evidence for {scenario_id} exceeds 12 items")
        if status_value == "automated" and not evidence:
            fail(f"automated scenario {scenario_id} needs test evidence")
        note = entry.get("note")
        if status_value != "automated" and (
            not isinstance(note, str) or not note or len(note) > 500
        ):
            fail(f"non-automated scenario {scenario_id} needs a bounded note")
        coverage_by_id[scenario_id] = entry

    missing = sorted(set(scenario_by_id) - set(coverage_by_id))
    unknown = sorted(set(coverage_by_id) - set(scenario_by_id))
    if missing or unknown:
        fail(f"coverage drift: missing={missing}, unknown={unknown}")

    results: list[dict[str, Any]] = []
    for scenario in scenarios:
        scenario_id = scenario["id"]
        coverage = coverage_by_id[scenario_id]
        result = {
            "id": scenario_id,
            "category": scenario["category"],
            "expected": scenario["expected"],
            "status": coverage["status"],
            "evidence": coverage["evidence"],
        }
        if "note" in coverage:
            result["note"] = coverage["note"]
        results.append(result)
    return results


def assert_output_safe(output: Path, inputs: list[tuple[str, Path]]) -> Path:
    absolute = output.absolute()
    for label, input_path in inputs:
        if absolute == input_path.absolute():
            fail(f"report output may not overwrite {label}")
    parent = absolute.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
        if parent.resolve(strict=True) != parent:
            fail("report output directory may not resolve through a symlink")
        if absolute.exists() or absolute.is_symlink():
            metadata = absolute.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                fail("report output must be a regular, non-symlink file when it exists")
    except OSError as exc:
        fail(f"failed to prepare report output {output}: {exc}")
    return absolute


def atomic_write_json(output: Path, value: dict[str, Any]) -> None:
    encoded = (json.dumps(value, indent=2) + "\n").encode("utf-8")
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{output.name}.",
            suffix=".tmp",
            dir=output.parent,
        )
        temporary = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
    except OSError as exc:
        try:
            temporary.unlink(missing_ok=True)
        except (OSError, UnboundLocalError):
            pass
        fail(f"failed to write report {output}: {exc}")


def generate_report(
    *,
    host: str,
    scenario_doc: dict[str, Any],
    coverage_doc: dict[str, Any],
    provenance: dict[str, Any],
    scenario_bytes: bytes,
    report_schema_bytes: bytes,
) -> dict[str, Any]:
    validated_provenance = validate_provenance(
        provenance,
        host=host,
        scenario_bytes=scenario_bytes,
        report_schema_bytes=report_schema_bytes,
    )
    results = validate_coverage(scenario_doc, coverage_doc, host)
    counts = {"automated": 0, "inventory-only": 0, "not-applicable": 0}
    for result in results:
        counts[result["status"]] += 1

    return {
        "reportVersion": "1.1.0",
        "scenarioVersion": scenario_doc["scenarioVersion"],
        "host": host,
        "generatedAt": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "provenance": validated_provenance,
        "summary": {
            "total": len(results),
            "automated": counts["automated"],
            "inventoryOnly": counts["inventory-only"],
            "notApplicable": counts["not-applicable"],
        },
        "results": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, choices=tuple(HOST_REPOSITORIES))
    parser.add_argument("--scenarios", required=True, type=Path)
    parser.add_argument("--coverage", required=True, type=Path)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--report-schema", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    scenario_doc, scenario_bytes = read_json(args.scenarios, "scenario inventory")
    coverage_doc, _ = read_json(args.coverage, "coverage inventory")
    provenance, _ = read_json(args.provenance, "conformance provenance")
    _, report_schema_bytes = read_json(args.report_schema, "conformance report schema")

    output = assert_output_safe(
        args.output,
        [
            ("scenario inventory", args.scenarios),
            ("coverage inventory", args.coverage),
            ("conformance provenance", args.provenance),
            ("conformance report schema", args.report_schema),
        ],
    )
    report = generate_report(
        host=args.host,
        scenario_doc=scenario_doc,
        coverage_doc=coverage_doc,
        provenance=provenance,
        scenario_bytes=scenario_bytes,
        report_schema_bytes=report_schema_bytes,
    )
    atomic_write_json(output, report)
    print(json.dumps(report["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
