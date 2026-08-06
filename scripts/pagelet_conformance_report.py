#!/usr/bin/env python3
"""Generate an honest pagelet conformance coverage report.

The focused test command must succeed before this script runs. The committed
coverage file then declares which canonical scenarios those tests automate and
which remain inventory-only or not applicable to this host.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any

ALLOWED_STATUS = {"automated", "inventory-only", "not-applicable"}


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"failed to read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"{path} must contain a JSON object")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, choices=("flutter", "rust-desktop"))
    parser.add_argument("--scenarios", required=True, type=Path)
    parser.add_argument("--coverage", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    scenario_doc = read_json(args.scenarios)
    coverage_doc = read_json(args.coverage)
    scenarios = scenario_doc.get("scenarios")
    entries = coverage_doc.get("entries")
    if not isinstance(scenarios, list) or not scenarios:
        raise SystemExit("scenario inventory must contain a non-empty scenarios array")
    if coverage_doc.get("coverageVersion") != "1.0.0":
        raise SystemExit("unsupported coverageVersion")
    if coverage_doc.get("host") != args.host:
        raise SystemExit("coverage host does not match --host")
    if not isinstance(entries, list):
        raise SystemExit("coverage must contain an entries array")

    scenario_by_id: dict[str, dict[str, Any]] = {}
    for scenario in scenarios:
        if not isinstance(scenario, dict) or not isinstance(scenario.get("id"), str):
            raise SystemExit("every scenario must be an object with a string id")
        scenario_id = scenario["id"]
        if scenario_id in scenario_by_id:
            raise SystemExit(f"duplicate scenario id: {scenario_id}")
        scenario_by_id[scenario_id] = scenario

    coverage_by_id: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise SystemExit("every coverage entry must be an object with a string id")
        scenario_id = entry["id"]
        if scenario_id in coverage_by_id:
            raise SystemExit(f"duplicate coverage id: {scenario_id}")
        status = entry.get("status")
        evidence = entry.get("evidence")
        if status not in ALLOWED_STATUS:
            raise SystemExit(f"invalid coverage status for {scenario_id}: {status}")
        if not isinstance(evidence, list) or not all(
            isinstance(item, str) and item for item in evidence
        ):
            raise SystemExit(f"coverage evidence for {scenario_id} must be string array")
        if status == "automated" and not evidence:
            raise SystemExit(f"automated scenario {scenario_id} needs test evidence")
        if status != "automated" and not isinstance(entry.get("note"), str):
            raise SystemExit(f"non-automated scenario {scenario_id} needs a note")
        coverage_by_id[scenario_id] = entry

    missing = sorted(set(scenario_by_id) - set(coverage_by_id))
    unknown = sorted(set(coverage_by_id) - set(scenario_by_id))
    if missing or unknown:
        raise SystemExit(f"coverage drift: missing={missing}, unknown={unknown}")

    results: list[dict[str, Any]] = []
    counts = {"automated": 0, "inventory-only": 0, "not-applicable": 0}
    for scenario in scenarios:
        scenario_id = scenario["id"]
        coverage = coverage_by_id[scenario_id]
        status = coverage["status"]
        counts[status] += 1
        result = {
            "id": scenario_id,
            "category": scenario["category"],
            "expected": scenario["expected"],
            "status": status,
            "evidence": coverage["evidence"],
        }
        if "note" in coverage:
            result["note"] = coverage["note"]
        results.append(result)

    report = {
        "reportVersion": "1.0.0",
        "scenarioVersion": scenario_doc.get("scenarioVersion"),
        "host": args.host,
        "generatedAt": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "summary": {
            "total": len(results),
            "automated": counts["automated"],
            "inventoryOnly": counts["inventory-only"],
            "notApplicable": counts["not-applicable"],
        },
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
