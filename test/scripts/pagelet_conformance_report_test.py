from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[2] / "scripts" / "pagelet_conformance_report.py"
SPEC = importlib.util.spec_from_file_location("pagelet_conformance_report", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class PageletConformanceReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.scenario_bytes = (
            json.dumps(
                {
                    "scenarioVersion": "1.0.0",
                    "scenarios": [
                        {
                            "id": "valid-device-summary",
                            "category": "parse",
                            "expected": "accept",
                        },
                        {
                            "id": "html-script-free",
                            "category": "html",
                            "expected": "script-free",
                        },
                    ],
                },
                separators=(",", ":"),
            )
            + "\n"
        ).encode()
        self.schema_bytes = b'{"type":"object"}\n'
        self.scenario_doc = json.loads(self.scenario_bytes)
        self.coverage_doc = {
            "coverageVersion": "1.0.0",
            "host": "flutter",
            "entries": [
                {
                    "id": "valid-device-summary",
                    "status": "automated",
                    "evidence": ["test/pagelet_renderer_test.dart"],
                },
                {
                    "id": "html-script-free",
                    "status": "not-applicable",
                    "evidence": [],
                    "note": "Flutter has no interactive HTML renderer.",
                },
            ],
        }
        self.provenance = {
            "interfaceRepository": "sonus-auris/sonus-auris-interfaces",
            "interfaceCommitSha": "a" * 40,
            "interfacePayloadTreeSha256": "b" * 64,
            "interfaceBundleSchemaVersion": 1,
            "scenarioPath": "pagelets/v1/conformance-scenarios.json",
            "scenarioSha256": sha256(self.scenario_bytes),
            "reportSchemaPath": "pagelets/v1/conformance-report.schema.json",
            "reportSchemaSha256": sha256(self.schema_bytes),
            "hostRepository": "sonus-auris/sonus-auris-ui.dart",
            "hostCommitSha": "c" * 40,
            "runUrl": (
                "https://github.com/sonus-auris/sonus-auris-ui.dart/"
                "actions/runs/123456"
            ),
        }

    def generate(self, **overrides: object) -> dict[str, object]:
        arguments = {
            "host": "flutter",
            "scenario_doc": self.scenario_doc,
            "coverage_doc": self.coverage_doc,
            "provenance": self.provenance,
            "scenario_bytes": self.scenario_bytes,
            "report_schema_bytes": self.schema_bytes,
            **overrides,
        }
        return module.generate_report(**arguments)

    def test_valid_report_is_v11_and_preserves_exact_provenance(self) -> None:
        report = self.generate()
        self.assertEqual(report["reportVersion"], "1.1.0")
        self.assertEqual(report["host"], "flutter")
        self.assertEqual(report["provenance"], self.provenance)
        self.assertEqual(
            report["summary"],
            {
                "total": 2,
                "automated": 1,
                "inventoryOnly": 0,
                "notApplicable": 1,
            },
        )

    def test_provenance_requires_exact_keys(self) -> None:
        missing = dict(self.provenance)
        missing.pop("interfaceCommitSha")
        with self.assertRaises(SystemExit):
            self.generate(provenance=missing)

        unknown = {**self.provenance, "branch": "main"}
        with self.assertRaises(SystemExit):
            self.generate(provenance=unknown)

    def test_provenance_rejects_identity_and_digest_drift(self) -> None:
        cases = [
            ("interfaceRepository", "other/interfaces"),
            ("interfaceCommitSha", "abc123"),
            ("interfaceCommitSha", "A" * 40),
            ("interfacePayloadTreeSha256", "B" * 64),
            ("interfaceBundleSchemaVersion", 2),
            ("scenarioPath", "copied/scenarios.json"),
            ("scenarioSha256", "d" * 64),
            ("reportSchemaPath", "copied/report-schema.json"),
            ("reportSchemaSha256", "e" * 64),
            ("hostRepository", "sonus-auris/desktop.app.rs"),
            ("hostCommitSha", "f" * 39),
        ]
        for field, replacement in cases:
            with self.subTest(field=field):
                provenance = {**self.provenance, field: replacement}
                with self.assertRaises(SystemExit):
                    self.generate(provenance=provenance)

    def test_actions_run_url_must_belong_to_flutter_repository(self) -> None:
        provenance = {
            **self.provenance,
            "runUrl": (
                "https://github.com/sonus-auris/desktop.app.rs/"
                "actions/runs/123456"
            ),
        }
        with self.assertRaises(SystemExit):
            self.generate(provenance=provenance)

    def test_scenario_or_schema_byte_changes_invalidate_provenance(self) -> None:
        with self.assertRaises(SystemExit):
            self.generate(scenario_bytes=self.scenario_bytes + b"\n")
        with self.assertRaises(SystemExit):
            self.generate(report_schema_bytes=self.schema_bytes + b"\n")

    def test_coverage_drift_and_disposition_errors_fail_closed(self) -> None:
        missing = json.loads(json.dumps(self.coverage_doc))
        missing["entries"].pop()
        with self.assertRaises(SystemExit):
            self.generate(coverage_doc=missing)

        no_evidence = json.loads(json.dumps(self.coverage_doc))
        no_evidence["entries"][0]["evidence"] = []
        with self.assertRaises(SystemExit):
            self.generate(coverage_doc=no_evidence)

        no_note = json.loads(json.dumps(self.coverage_doc))
        no_note["entries"][1].pop("note")
        with self.assertRaises(SystemExit):
            self.generate(coverage_doc=no_note)

    def test_output_is_atomic_private_and_cannot_overwrite_inputs(self) -> None:
        scenario_path = self.root / "scenarios.json"
        coverage_path = self.root / "coverage.json"
        provenance_path = self.root / "provenance.json"
        schema_path = self.root / "schema.json"
        for path, value in (
            (scenario_path, self.scenario_doc),
            (coverage_path, self.coverage_doc),
            (provenance_path, self.provenance),
            (schema_path, {"type": "object"}),
        ):
            path.write_text(json.dumps(value) + "\n", encoding="utf-8")

        for input_path in (
            scenario_path,
            coverage_path,
            provenance_path,
            schema_path,
        ):
            with self.assertRaises(SystemExit):
                module.assert_output_safe(
                    input_path,
                    [
                        ("scenario", scenario_path),
                        ("coverage", coverage_path),
                        ("provenance", provenance_path),
                        ("schema", schema_path),
                    ],
                )

        output = module.assert_output_safe(
            self.root / "out" / "report.json",
            [("scenario", scenario_path)],
        )
        report = self.generate()
        module.atomic_write_json(output, report)
        persisted = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(persisted["reportVersion"], "1.1.0")
        if os.name != "nt":
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)

    def test_symlink_output_and_symlinked_parent_are_rejected(self) -> None:
        target = self.root / "target.json"
        target.write_text("{}\n", encoding="utf-8")
        output_link = self.root / "report-link.json"
        real_directory = self.root / "real"
        linked_directory = self.root / "linked"
        real_directory.mkdir()
        try:
            output_link.symlink_to(target)
            linked_directory.symlink_to(real_directory, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")

        with self.assertRaises(SystemExit):
            module.assert_output_safe(output_link, [])
        with self.assertRaises(SystemExit):
            module.assert_output_safe(linked_directory / "report.json", [])


if __name__ == "__main__":
    unittest.main()
