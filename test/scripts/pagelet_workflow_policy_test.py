from __future__ import annotations

import unittest
from pathlib import Path

WORKFLOW = (
    Path(__file__).parents[2]
    / ".github"
    / "workflows"
    / "pagelet-conformance.yml"
)


class PageletWorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = WORKFLOW.read_text(encoding="utf-8")

    def test_cross_repository_access_uses_one_pinned_github_app_action(self) -> None:
        action = (
            "actions/create-github-app-token@"
            "fee1f7d63c2ff003460e3d139729b119787bc349"
        )
        self.assertEqual(self.source.count(action), 1)
        self.assertIn("# v2.2.2", self.source)
        self.assertIn("owner: sonus-auris", self.source)
        self.assertIn("repositories: sonus-auris-interfaces", self.source)
        self.assertIn("permission-contents: read", self.source)

    def test_interface_checkout_consumes_only_the_app_token(self) -> None:
        self.assertIn(
            "token: ${{ steps.interface-app-token.outputs.token }}",
            self.source,
        )
        self.assertGreaterEqual(
            self.source.count("persist-credentials: false"),
            2,
        )

    def test_personal_or_default_tokens_are_not_cross_repo_fallbacks(self) -> None:
        forbidden = [
            "SONUS_INTERFACES_READ_TOKEN",
            "secrets.GITHUB_TOKEN",
            "github.token",
            "ghp_",
            "personal access token",
        ]
        lower_source = self.source.lower()
        for value in forbidden:
            self.assertNotIn(value.lower(), lower_source, value)

    def test_app_credentials_have_one_reviewed_name_and_clear_preflight(self) -> None:
        self.assertGreaterEqual(
            self.source.count("SONUS_CROSS_REPO_APP_ID"),
            3,
        )
        self.assertGreaterEqual(
            self.source.count("SONUS_CROSS_REPO_APP_PRIVATE_KEY"),
            3,
        )
        self.assertIn(
            "Immutable interface checkout requires the Sonus cross-repository GitHub App",
            self.source,
        )

    def test_interface_identity_is_rechecked_after_checkout(self) -> None:
        self.assertIn(
            'actual="$(git -C .interface-contract rev-parse HEAD)"',
            self.source,
        )
        self.assertIn('test "$actual" = "$EXPECTED_INTERFACE_SHA"', self.source)
        self.assertIn(
            'test -z "$(git -C .interface-contract status --porcelain)"',
            self.source,
        )


if __name__ == "__main__":
    unittest.main()
