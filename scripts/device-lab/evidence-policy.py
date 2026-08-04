#!/usr/bin/env python3
"""Sanitize and verify Sonus Auris device-lab evidence.

The policy is intentionally dependency-light so it can run on a developer Mac
and in GitHub Actions. It never follows symlinks, never reads raw audio, waits
for evidence writers to finish, and only rewrites small UTF-8 text files when
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
SECRET_KEY = (
    r"(?:access[_-]?token|refresh[_-]?token|id[_-]?token|provider[_-]?token|"
    r"token|api[_-]?key|anon[_-]?key|code[_-]?verifier|"
    r"authorization[_-]?code|auth[_-]?code|otp)"
)
STRONG_SPACE_KEY = (
    r"(?:access[_-]?token|refresh[_-]?token|id[_-]?token|provider[_-]?token|"
    r"api[_-]?key|anon[_-]?key|code[_-]?verifier|"
    r"authorization[_-]?code|auth[_-]?code)"
)


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
        "windows-user-path",
        re.compile(r"(?i)\\Users\\(?!<redacted>)[^\\\s]+"),
        r"\\Users\\<redacted>",
    ),
    Redaction(
        "url-basic-auth",
        re.compile(r"(?i)([a-z][a-z0-9+.-]*://)[^/@\s:]+:[^/@\s]+@"),
        r"\1<redacted-userinfo>@",
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
            rf"(?ix)(?<![A-Za-z0-9_])"
            rf"([\"']?{SECRET_KEY}[\"']?\s*(?:=|:)\s*[\"']?)"
            rf"((?!<redacted>)[^&;,}}\s\"']+)"
        ),
        r"\1<redacted>",
    ),
    Redaction(
        "encoded-auth-parameter",
        re.compile(rf"(?ix)({SECRET_KEY}%3[dD])((?!<redacted>)[^%&\s]+)"),
        r"\1<redacted>",
    ),
    Redaction(
        "space-auth-parameter",
        re.compile(
            rf"(?ix)(?<![A-Za-z0-9_])({STRONG_SPACE_KEY}\s+)"
            rf"((?!<redacted>)[A-Za-z0-9._~+/%=-]{{4,}})"
        ),
        r"\1<redacted>",
    ),
    Redaction(
        "space-otp",
        re.compile(r"(?i)(?<![A-Za-z0-9_])(\botp\s+)(\d{4,10})"),
        r"\1<redacted>",
    ),
    Redaction(
        "email",
        re.compile(
            r"(?i)(?![A-Za-z0-9._%+-]+@\d+x\.(?:png|jpe?g|gif|webp|svg)\b)"
            r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
        ),
        "<redacted-email>",
    ),
    Redaction(
        "phone",
        re.compile(
            r"(?i)(\b(?:phone|phone[_-]?number|mobile|msisdn)\s*"
            r"(?:=|:)\s*)(?:\+?\d[\d .()\-]{6,}\d)"
        ),
        r"\1<redacted-phone>",
    ),
    Redaction(
        "uuid",
        re.compile(
            r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
        ),
        "<redacted-uuid>",
    ),
    Redaction(
        "ios-device-id",
        re.compile(r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b"),
        "<redacted-ios-device>",
    ),
    Redaction(
        "device-id",
        re.compile(
            r"(?i)(\b(?:device|device[_-]?id|serial|udid)\s*(?:=|:)\s*)"
            r"[A-Za-z0-9._:-]{8,}"
        ),
        r"\1<redacted-device>",
    ),
    Redaction(
        "vm-service",
        re.compile(r"(?i)\b((?:https?|wss?)://127\.0\.0\.1):\d+/[^\s]*"),
        r"\1:<port>/<redacted>",
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
        help="atomically redact recognized secrets and local account paths",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run dependency-free policy regression tests",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="sanitize stdin to stdout for live evidence capture",
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

    minimum_observation = 0.8 if path.name in LIVE_LOG_NAMES else 0.2
    stable_since: float | None = None
    previous: tuple[int, int] | None = None
    while time.monotonic() < deadline:
        try:
            metadata = path.stat()
        except OSError as error:
            raise ValueError(f"cannot stat evidence file {path}: {error}") from error
        signature = (metadata.st_size, metadata.st_mtime_ns)
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
        "symlinks_present=false\n",
        encoding="utf-8",
    )
    return text_files, redacted_files


def run_self_test() -> None:
    secrets = {
        "query": "access_token=SYNTHETIC_SECRET&otp=654321",
        "json": '{"access_token":"SYNTHETIC_SECRET","otp":"654321"}',
        "colon": "access_token: SYNTHETIC_SECRET; otp: 654321",
        "space": "code_verifier SYNTHETIC_SECRET",
        "cookie": "Set-Cookie: refresh_token=SYNTHETIC_SECRET; HttpOnly",
        "fragment": (
            "sonusauris://callback#access_token=SYNTHETIC_SECRET"
            "&id_token=SYNTHETIC_ID"
        ),
        "bearer": "Authorization: Bearer SYNTHETIC.bearer-token_123",
        "basic-auth": "https://synthetic-user:synthetic-pass@example.invalid/private",
        "email": "account=synthetic@example.invalid",
        "phone": "phone=+1 (202) 555-0199",
        "home": "/Users/synthetic-user/codes/sonus",
        "uuid": "11111111-2222-3333-4444-555555555555",
        "ios-device": "device=00008120-001234567890001E",
        "encoded": "access_token%3DSYNTHETIC_SECRET%26otp%3D654321",
        "jwt": "eyJabcdefgh.ijklmnop.qrstuvwx",
        "loopback": "ws://127.0.0.1:54321/secret/path?token=SYNTHETIC_SECRET",
        "github": "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
        "openai": "sk-abcdefghijklmnopqrstuvwxyz1234567890",
    }
    forbidden = (
        "SYNTHETIC_SECRET",
        "SYNTHETIC_ID",
        "654321",
        "synthetic-user",
        "synthetic-pass",
        "synthetic@example.invalid",
        "202) 555",
        "11111111-2222",
        "00008120-001234567890001E",
        "eyJabcdefgh",
        "/secret/path",
        "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
        "sk-abcdefghijklmnopqrstuvwxyz1234567890",
    )
    ordinary = (
        "token count: 42",
        "code: 404",
        "otp retries remaining: 3",
        "AppIcon60x60@2x.png",
    )

    with tempfile.TemporaryDirectory(prefix="sonus-evidence-policy-") as temp:
        root = Path(temp)
        fixture = root / "fixture.txt"
        run_log = root / "run.log"
        fixture.write_text("\n".join(secrets.values()) + "\n", encoding="utf-8")
        run_log.touch()
        writer = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import pathlib,sys,time; "
                    "p=pathlib.Path(sys.argv[1]); "
                    "f=p.open('w', encoding='utf-8'); "
                    "time.sleep(0.35); "
                    "f.write('CoreSimulator/Devices/"
                    "11111111-2222-3333-4444-555555555555/data\\n'); "
                    "f.flush(); f.close()"
                ),
                str(run_log),
            ]
        )
        time.sleep(0.05)
        inspect_evidence(root, redact=True)
        assert writer.wait(timeout=5) == 0
        clean = fixture.read_text(encoding="utf-8") + run_log.read_text(encoding="utf-8")
        for marker in forbidden:
            assert marker not in clean, marker
        for line in ordinary:
            sanitized, _ = sanitize_text(line)
            assert sanitized == line, (line, sanitized)
        assert remaining_violations(clean) == set()

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

    with tempfile.TemporaryDirectory(prefix="sonus-evidence-policy-symlink-") as temp:
        root = Path(temp)
        target = root / "target.txt"
        target.write_text("safe\n", encoding="utf-8")
        (root / "link.txt").symlink_to(target.name)
        try:
            inspect_evidence(root, redact=True)
        except ValueError as error:
            assert "symlink evidence is forbidden" in str(error)
        else:
            raise AssertionError("symlink unexpectedly passed evidence policy")

    print(
        "Sonus Auris evidence policy self-test passed: "
        f"{len(secrets)} secret cases + {len(ordinary)} preservation cases"
    )


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0
    if args.stream:
        if args.evidence_dir is not None or args.redact:
            raise ValueError("--stream cannot be combined with evidence_dir or --redact")
        for line in sys.stdin:
            clean, _ = sanitize_text(line)
            sys.stdout.write(clean)
            sys.stdout.flush()
        return 0
    if args.evidence_dir is None:
        raise ValueError("evidence_dir is required unless --self-test or --stream is used")
    scanned, redacted = inspect_evidence(args.evidence_dir, args.redact)
    print(f"Evidence policy passed: scanned={scanned} redacted={redacted}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (AssertionError, OSError, ValueError) as error:
        print(f"evidence-policy: {error}", file=sys.stderr)
        raise SystemExit(1)
