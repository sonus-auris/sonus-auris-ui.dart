#!/usr/bin/env python3
"""Sanitize and verify Sonus Auris device-lab evidence.

The policy is intentionally dependency-light so it can run on a developer Mac
and in GitHub Actions. It never follows symlinks, never reads raw audio, waits
for log writers to finish, and only rewrites small UTF-8 text files when
--redact is explicitly selected.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

MAX_TEXT_BYTES = 5 * 1024 * 1024
WRITER_WAIT_SECONDS = 15.0
LIVE_LOG_NAMES = {"run.log", "orchestrator.log"}
SENSITIVE_SUFFIXES = {
    ".aac",
    ".caf",
    ".der",
    ".flac",
    ".key",
    ".m4a",
    ".mobileprovision",
    ".mp3",
    ".p12",
    ".pem",
    ".pfx",
    ".pcm",
    ".wav",
}


@dataclass(frozen=True)
class Redaction:
    name: str
    pattern: re.Pattern[str]
    replacement: str


REDACTIONS = (
    Redaction(
        "mac-user-path",
        re.compile(r"/Users/(?!<redacted>)[^/\s]+"),
        "/Users/<redacted>",
    ),
    Redaction(
        "uuid",
        re.compile(
            r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-"
            r"[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}\b"
        ),
        "<redacted-uuid>",
    ),
    Redaction(
        "bearer-token",
        re.compile(r"(?i)Bearer\s+(?!<redacted>)[A-Za-z0-9._~+/=-]+"),
        "Bearer <redacted>",
    ),
    Redaction(
        "jwt",
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"
        ),
        "<redacted-jwt>",
    ),
    Redaction(
        "auth-parameter",
        re.compile(
            r"(?i)(access_token|refresh_token|id_token|provider_token|token|apikey|"
            r"code_verifier|authorization_code|auth_code|otp)=((?!<redacted>)[^&\s]+)"
        ),
        r"\1=<redacted>",
    ),
    Redaction(
        "email",
        re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
        "<redacted-email>",
    ),
    Redaction(
        "vm-service-http",
        re.compile(r"http://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"),
        "http://127.0.0.1:<port>/<redacted>",
    ),
    Redaction(
        "vm-service-ws",
        re.compile(r"ws://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"),
        "ws://127.0.0.1:<port>/<redacted>",
    ),
    Redaction(
        "github-token",
        re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
        "<redacted-github-token>",
    ),
    Redaction(
        "openai-key",
        re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
        "<redacted-api-key>",
    ),
)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence_dir", nargs="?", type=Path)
    parser.add_argument(
        "--redact",
        action="store_true",
        help="atomically redact recognized secrets, identifiers, and local paths",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run dependency-free policy regression tests",
    )
    return parser.parse_args(argv)


def wait_for_quiescent_file(path: Path) -> None:
    """Wait until no observable writer owns path and its metadata is stable."""

    deadline = time.monotonic() + WRITER_WAIT_SECONDS
    lsof = shutil.which("lsof")
    if lsof is not None:
        while time.monotonic() < deadline:
            result = subprocess.run(
                [lsof, "-t", str(path)],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            if not result.stdout.strip():
                break
            time.sleep(0.1)
        else:
            raise ValueError(f"evidence log still has an open writer: {path.name}")

    # Bash process substitutions can outlive the parent shell briefly. Requiring
    # a stable size/mtime window prevents an atomic redaction from racing a late
    # `tee` flush even where `lsof` is unavailable.
    minimum_observation = 0.8 if path.name in LIVE_LOG_NAMES else 0.2
    stable_since: float | None = None
    previous: tuple[int, int] | None = None
    while time.monotonic() < deadline:
        try:
            stat = path.stat()
        except OSError as error:
            raise ValueError(f"cannot stat evidence file {path}: {error}") from error
        signature = (stat.st_size, stat.st_mtime_ns)
        now = time.monotonic()
        if signature == previous:
            if stable_since is None:
                stable_since = now
            if now - stable_since >= minimum_observation:
                return
        else:
            previous = signature
            stable_since = now
        time.sleep(0.1)
    raise ValueError(f"evidence file did not become quiescent: {path.name}")


def is_probably_text(path: Path) -> bool:
    try:
        size = path.stat().st_size
    except OSError:
        return False
    if size > MAX_TEXT_BYTES:
        return False
    try:
        sample = path.read_bytes()[:8192]
    except OSError:
        return False
    return b"\x00" not in sample


def sanitize_text(text: str) -> tuple[str, set[str]]:
    changed: set[str] = set()
    clean = text
    for redaction in REDACTIONS:
        clean, count = redaction.pattern.subn(redaction.replacement, clean)
        if count:
            changed.add(redaction.name)
    return clean, changed


def remaining_violations(text: str) -> set[str]:
    violations: set[str] = set()
    for redaction in REDACTIONS:
        if redaction.pattern.search(text):
            violations.add(redaction.name)
    return violations


def atomic_write(path: Path, text: str) -> None:
    mode = path.stat().st_mode & 0o777
    temporary = path.with_name(f".{path.name}.sonus-evidence-{os.getpid()}")
    temporary.write_text(text, encoding="utf-8")
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def inspect_evidence(root: Path, redact: bool) -> tuple[int, int]:
    if not root.is_dir():
        raise ValueError(f"evidence directory does not exist: {root}")

    text_files = 0
    redacted_files = 0
    failures: list[str] = []

    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if path.is_symlink():
            failures.append(f"symlink evidence is forbidden: {relative}")
            continue
        if not path.is_file():
            continue
        if path.suffix.lower() in SENSITIVE_SUFFIXES:
            failures.append(f"sensitive/raw artifact is forbidden: {relative}")
            continue
        wait_for_quiescent_file(path)
        if not is_probably_text(path):
            continue
        try:
            original = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        text_files += 1
        clean, changed = sanitize_text(original)
        if changed and redact:
            atomic_write(path, clean)
            redacted_files += 1
        candidate = clean if redact else original
        violations = remaining_violations(candidate)
        if violations:
            failures.append(
                f"unredacted {','.join(sorted(violations))} in {relative}"
            )

    if failures:
        raise ValueError("; ".join(failures))

    report = root / "evidence-policy.txt"
    report.write_text(
        "status=passed\n"
        f"text_files_scanned={text_files}\n"
        f"text_files_redacted={redacted_files}\n"
        "writers_quiescent=true\n"
        "raw_audio_present=false\n"
        "secret_patterns_present=false\n"
        "raw_identifiers_present=false\n"
        "symlinks_present=false\n",
        encoding="utf-8",
    )
    return text_files, redacted_files


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="sonus-evidence-policy-") as temp:
        root = Path(temp)
        fixture = root / "run.log"
        fixture.touch()
        writer = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import pathlib,sys,time; "
                    "p=pathlib.Path(sys.argv[1]); "
                    "f=p.open('w', encoding='utf-8'); "
                    "time.sleep(0.5); "
                    "f.write('/Users/alex/work account@example.com Bearer abc.def.ghi '"
                    "'access_token=secret http://127.0.0.1:12345/abc=/ '"
                    "'ws://127.0.0.1:12345/abc=/ '"
                    "'9E2C2CF0-7DD4-4B9D-B6CE-63C9E42B95A7\\n'); "
                    "f.flush(); f.close()"
                ),
                str(fixture),
            ]
        )
        time.sleep(0.1)
        inspect_evidence(root, redact=True)
        assert writer.wait(timeout=5) == 0
        clean = fixture.read_text(encoding="utf-8")
        assert "/Users/alex" not in clean
        assert "account@example.com" not in clean
        assert "access_token=secret" not in clean
        assert "127.0.0.1:12345/abc" not in clean
        assert "9E2C2CF0-7DD4-4B9D-B6CE-63C9E42B95A7" not in clean
        assert "<redacted-uuid>" in clean

    with tempfile.TemporaryDirectory(prefix="sonus-evidence-policy-audio-") as temp:
        root = Path(temp)
        (root / "raw.wav").write_bytes(b"RIFF")
        try:
            inspect_evidence(root, redact=True)
        except ValueError as error:
            assert "raw.wav" in str(error)
        else:
            raise AssertionError("raw audio unexpectedly passed evidence policy")

    with tempfile.TemporaryDirectory(prefix="sonus-evidence-policy-secret-") as temp:
        root = Path(temp)
        (root / "secret.txt").write_text("Bearer topsecret\n", encoding="utf-8")
        try:
            inspect_evidence(root, redact=False)
        except ValueError as error:
            assert "bearer-token" in str(error)
        else:
            raise AssertionError("unredacted secret unexpectedly passed verify-only mode")

    print("Sonus Auris evidence policy self-test passed")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0
    if args.evidence_dir is None:
        raise ValueError("evidence_dir is required unless --self-test is used")
    scanned, redacted = inspect_evidence(args.evidence_dir, args.redact)
    print(f"Evidence policy passed: scanned={scanned} redacted={redacted}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (AssertionError, OSError, ValueError) as error:
        print(f"evidence-policy: {error}", file=sys.stderr)
        raise SystemExit(1)
