#!/usr/bin/env python3
"""Require artifact upload to be gated on successful evidence sanitization."""

from __future__ import annotations

import argparse
from pathlib import Path

POLICY_ID = "evidence_policy"
SAFE_CONDITION = "steps.evidence_policy.outcome == 'success'"


def step_blocks(text: str) -> list[list[str]]:
    blocks: list[list[str]] = []
    current: list[str] = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("- name:") or stripped.startswith("- uses:"):
            if current:
                blocks.append(current)
            current = [line]
        elif current:
            current.append(line)
    if current:
        blocks.append(current)
    return blocks


def validate(text: str) -> list[str]:
    problems: list[str] = []
    blocks = step_blocks(text)
    policies = [block for block in blocks if any(f"id: {POLICY_ID}" in line for line in block)]
    uploads = [block for block in blocks if any("actions/upload-artifact@" in line for line in block)]
    if not policies:
        problems.append("no evidence-policy step with id: evidence_policy")
    else:
        for block in policies:
            if "if: always()" not in "\n".join(block):
                problems.append("evidence-policy step is not configured with if: always()")
    if not uploads:
        problems.append("no upload-artifact step found")
    for block in uploads:
        if SAFE_CONDITION not in "\n".join(block):
            problems.append("upload-artifact is not gated on evidence-policy success")
    return problems


def self_test() -> None:
    safe = """
      - name: Redact and verify evidence
        id: evidence_policy
        if: always()
        run: python3 evidence-policy.py --redact evidence
      - name: Upload sanitized evidence
        if: ${{ always() && steps.evidence_policy.outcome == 'success' }}
        uses: actions/upload-artifact@deadbeef
"""
    unsafe_always = """
      - name: Redact and verify evidence
        id: evidence_policy
        if: always()
        run: python3 evidence-policy.py --redact evidence
      - name: Upload evidence
        if: always()
        uses: actions/upload-artifact@deadbeef
"""
    missing_id = """
      - name: Redact evidence
        if: always()
        run: python3 evidence-policy.py --redact evidence
      - name: Upload evidence
        if: ${{ always() && steps.evidence_policy.outcome == 'success' }}
        uses: actions/upload-artifact@deadbeef
"""
    assert validate(safe) == []
    assert "upload-artifact is not gated on evidence-policy success" in validate(unsafe_always)
    assert "no evidence-policy step with id: evidence_policy" in validate(missing_id)
    print("Evidence upload gate self-test passed: safe + unsafe + missing-policy-id")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.workflow is None:
        parser.error("workflow is required unless --self-test is used")
    problems = validate(args.workflow.read_text(encoding="utf-8"))
    if problems:
        for problem in problems:
            print(f"evidence-upload-gate: {problem}")
        return 1
    print(f"Evidence upload gate passed: {args.workflow}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
