#!/usr/bin/env python3
"""Adversarial regression tests for the Sonus Android release boundary."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GRADLE = ROOT / "android/app/build.gradle.kts"
WORKFLOW = ROOT / ".github/workflows/android-release.yml"
TOOLING_WORKFLOW = ROOT / ".github/workflows/release-tooling-ci.yml"
VERIFY = ROOT / "scripts/release/verify-android-publication.sh"
BUILD_SCRIPTS = (
    ROOT / "scripts/release/android-build-aab.sh",
    ROOT / "scripts/release/android-build-apk.sh",
)


class AndroidReleaseContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.gradle = GRADLE.read_text(encoding="utf-8")
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.tooling_workflow = TOOLING_WORKFLOW.read_text(encoding="utf-8")
        cls.verify = VERIFY.read_text(encoding="utf-8")

    def test_package_contract_accepts_canonical_identity(self) -> None:
        completed = subprocess.run(
            [
                "python3",
                str(ROOT / "scripts/release/check_android_package_contract.py"),
                "--expected",
                "com.ores.sonus_auris",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_gradle_has_no_debug_release_fallback_or_bypass(self) -> None:
        self.assertNotIn('signingConfigs.getByName("debug")', self.gradle)
        self.assertNotIn("ALLOW_DEBUG_SIGNED_RELEASE", self.gradle)
        self.assertNotIn("allow_debug_signed_release", self.gradle)

    def test_gradle_requires_owner_pinned_fingerprint(self) -> None:
        self.assertIn("SONUS_ANDROID_UPLOAD_CERT_SHA256", self.gradle)
        self.assertIn("64-digit SHA-256 fingerprint", self.gradle)
        self.assertIn("owner-pinned upload fingerprint", self.gradle)

    def test_gradle_rejects_debug_signing_material(self) -> None:
        self.assertIn("androiddebugkey", self.gradle)
        self.assertIn("debug.keystore", self.gradle)
        self.assertIn("CN=Android Debug", self.gradle)

    def test_gradle_validates_alias_and_key_password(self) -> None:
        self.assertIn("isKeyEntry", self.gradle)
        self.assertIn("getKey(keyAlias, keyPassword.toCharArray())", self.gradle)
        self.assertIn("release key password is invalid", self.gradle)

    def test_release_workflow_is_manual_and_main_only(self) -> None:
        trigger = self.workflow.split("permissions:", maxsplit=1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotIn("pull_request:", trigger)
        self.assertNotIn("push:", trigger)
        self.assertIn("github.ref == 'refs/heads/main'", self.workflow)
        self.assertIn("name: mobile-production", self.workflow)

    def test_release_inputs_and_certificate_are_required(self) -> None:
        self.assertRegex(
            self.workflow,
            r"build_name:\s+description:.*\s+type: string\s+required: true",
        )
        self.assertRegex(
            self.workflow,
            r"build_number:\s+description:.*\s+type: string\s+required: true",
        )
        self.assertIn(
            "SONUS_ANDROID_UPLOAD_CERT_SHA256: ${{ secrets.ANDROID_UPLOAD_CERT_SHA256 }}",
            self.workflow,
        )

    def test_release_workflow_uses_locked_dependencies_and_ephemeral_key(self) -> None:
        self.assertIn("flutter pub get --enforce-lockfile", self.workflow)
        self.assertIn('$RUNNER_TEMP/sonus-auris-upload-keystore.jks', self.workflow)
        self.assertIn("ANDROID_UPLOAD_KEYSTORE_PATH=%s", self.workflow)
        self.assertIn("shred --force --remove", self.workflow)

    def test_release_actions_are_commit_pinned(self) -> None:
        actions = re.findall(
            r"^\s*(?:-\s+)?uses:\s*([^\s]+)",
            self.workflow,
            re.MULTILINE,
        )
        self.assertGreaterEqual(len(actions), 4)
        for action in actions:
            self.assertRegex(action, r"@[0-9a-f]{40}$")

    def test_verifier_binds_keystore_and_artifact_to_owner_fingerprint(self) -> None:
        self.assertIn('keystore_fingerprint" == "$owner_fingerprint', self.verify)
        self.assertIn('artifact_fingerprint" == "$owner_fingerprint', self.verify)
        self.assertIn("owner-pinned SHA-256 fingerprint is malformed", self.verify)

    def test_verifier_checksum_is_portable(self) -> None:
        self.assertIn("file_sha256()", self.verify)
        self.assertIn("shasum -a 256", self.verify)
        self.assertNotIn("sha256sum --check --status", self.verify)

    def test_verifier_normalizes_all_fingerprints(self) -> None:
        self.assertEqual(self.verify.count('gsub(/[^0-9A-Fa-f]/, "", $2)'), 2)
        self.assertIn("tr -d ':[:space:]'", self.verify)

    def test_every_release_entrypoint_requires_fingerprint(self) -> None:
        for path in BUILD_SCRIPTS:
            with self.subTest(path=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("SONUS_ANDROID_UPLOAD_CERT_SHA256 is required", text)
                self.assertIn("flutter pub get --enforce-lockfile", text)

    def test_release_tooling_uses_only_canonical_package(self) -> None:
        self.assertIn("--package-name com.ores.sonus_auris", self.tooling_workflow)
        self.assertNotIn("com.ores.audio_dashcam", self.tooling_workflow)
        self.assertIn("test_android_release_contract.py", self.tooling_workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
