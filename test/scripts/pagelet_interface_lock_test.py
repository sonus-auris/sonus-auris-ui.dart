from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[2] / "scripts" / "pagelet_interface_lock.py"
SPEC = importlib.util.spec_from_file_location("pagelet_interface_lock", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class InterfaceLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.lock_path = self.root / "interface-contract.lock.json"
        self.valid = {
            "schemaVersion": 1,
            "repository": "sonus-auris/sonus-auris-interfaces",
            "commitSha": "a" * 40,
        }

    def write_lock(self, value: object) -> None:
        self.lock_path.write_text(json.dumps(value) + "\n", encoding="utf-8")

    def test_valid_lock_is_normalized_and_writes_only_safe_outputs(self) -> None:
        self.write_lock(self.valid)
        self.assertEqual(module.load_lock(self.lock_path), self.valid)

        output = self.root / "github-output.txt"
        module.append_github_outputs(output, self.valid)
        self.assertEqual(
            output.read_text(encoding="utf-8"),
            "repository=sonus-auris/sonus-auris-interfaces\n"
            + f"commit={'a' * 40}\n",
        )

    def test_lock_requires_exact_keys(self) -> None:
        for mutation in (
            {"extra": True},
            {"commitSha": None},
        ):
            value = dict(self.valid)
            if mutation["commitSha"] if "commitSha" in mutation else False:
                pass
            value.update(mutation)
            if mutation.get("commitSha") is None and "commitSha" in mutation:
                value.pop("commitSha")
            self.write_lock(value)
            with self.assertRaises(SystemExit):
                module.load_lock(self.lock_path)

    def test_lock_rejects_mutable_or_ambiguous_identity(self) -> None:
        cases = [
            {**self.valid, "schemaVersion": 2},
            {**self.valid, "repository": "other/interfaces"},
            {**self.valid, "commitSha": "main"},
            {**self.valid, "commitSha": "abc123"},
            {**self.valid, "commitSha": "A" * 40},
        ]
        for value in cases:
            with self.subTest(value=value):
                self.write_lock(value)
                with self.assertRaises(SystemExit):
                    module.load_lock(self.lock_path)

    def test_lock_must_be_a_regular_non_symlink_file(self) -> None:
        target = self.root / "target.json"
        target.write_text(json.dumps(self.valid), encoding="utf-8")
        try:
            self.lock_path.symlink_to(target)
        except OSError as error:
            self.skipTest(f"symlinks unavailable: {error}")
        with self.assertRaises(SystemExit):
            module.load_lock(self.lock_path)

    def test_symlinked_parent_component_is_rejected(self) -> None:
        real_directory = self.root / "real"
        linked_directory = self.root / "linked"
        real_directory.mkdir()
        real_lock = real_directory / "lock.json"
        real_lock.write_text(json.dumps(self.valid), encoding="utf-8")
        try:
            linked_directory.symlink_to(real_directory, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"directory symlinks unavailable: {error}")
        with self.assertRaises(SystemExit):
            module.load_lock(linked_directory / "lock.json")


if __name__ == "__main__":
    unittest.main()
