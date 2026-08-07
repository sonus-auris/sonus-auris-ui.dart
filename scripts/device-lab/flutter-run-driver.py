#!/usr/bin/env python3
"""Drive a physical-device ``flutter run`` process without false positives.

A readiness marker alone is not success. The process must remain attached for a
bounded hold interval, accept the driver's normal ``q`` command, exit within a
second bounded interval, and emit no known build/device/runtime failure marker.
All live and retained output is sanitized. Retained output keeps bounded startup
and terminal windows instead of an unbounded or final-only log.
"""

from __future__ import annotations

import argparse
import codecs
import os
import re
import selectors
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence, TextIO

DEFAULT_MAX_LOG_BYTES = 512 * 1024
DEFAULT_QUIT_TIMEOUT_SECONDS = 30.0
READ_CHUNK_BYTES = 64 * 1024

READINESS_MARKERS = (
    "Flutter run key commands",
    "A Dart VM Service on",
    "The Flutter DevTools debugger and profiler",
)
FAILURE_MARKERS = (
    "Could not build the precompiled application for the device",
    "Failed to build iOS app",
    "No valid code signing certificates were found",
    "Error launching application on",
    "Lost connection to device",
    "Terminating app due to uncaught exception",
    "Fatal error",
    "EXC_CRASH",
    "SIGABRT",
    "Library not loaded",
    "Dart VM Service is no longer available",
)
REDACTIONS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"/Users/(?!<redacted>)[^/\s]+"), "/Users/<redacted>"),
    (
        re.compile(r"(?i)Bearer\s+(?!<redacted>)[A-Za-z0-9._~+/=-]+"),
        "Bearer <redacted>",
    ),
    (
        re.compile(
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."
            r"[A-Za-z0-9_-]{8,}\b"
        ),
        "<redacted-jwt>",
    ),
    (
        re.compile(
            r"(?i)(access_token|refresh_token|id_token|provider_token|token|"
            r"code_verifier|authorization_code|auth_code|otp)="
            r"((?!<redacted>)[^&\s]+)"
        ),
        r"\1=<redacted>",
    ),
    (
        re.compile(
            r"(?i)(?![A-Za-z0-9._%+-]+@\d+x\.(?:png|jpe?g|gif|webp|svg)\b)"
            r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"
        ),
        "<redacted-email>",
    ),
    (
        re.compile(r"https?://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"),
        "http://127.0.0.1:<port>/<redacted>",
    ),
    (
        re.compile(r"ws://127\.0\.0\.1:\d+/[A-Za-z0-9_=/.-]+"),
        "ws://127.0.0.1:<port>/<redacted>",
    ),
    (
        re.compile(
            r"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
            r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"
        ),
        "<redacted-uuid>",
    ),
    (re.compile(r"(?i)(on|for) [^\n]+ iPhone"), r"\1 <physical-iPhone>"),
)


def sanitize(text: str) -> str:
    clean = text
    for pattern, replacement in REDACTIONS:
        clean = pattern.sub(replacement, clean)
    return clean


def utf8_prefix(data: bytes, limit: int) -> bytes:
    return data[:limit].decode("utf-8", errors="ignore").encode("utf-8")


def utf8_suffix(data: bytes, limit: int) -> bytes:
    return data[-limit:].decode("utf-8", errors="ignore").encode("utf-8")


class BoundedLog:
    """Retain bounded startup and terminal windows with bounded memory."""

    def __init__(self, maximum: int) -> None:
        if maximum < 512:
            raise ValueError("max log bytes must be at least 512")
        self.maximum = maximum
        self.total = 0
        self._buffer = bytearray()
        self._head = bytearray()
        self._tail = bytearray()
        self._truncated = False

    def feed(self, text: str) -> None:
        chunk = text.encode("utf-8", errors="replace")
        self.total += len(chunk)
        if not self._truncated:
            self._buffer.extend(chunk)
            if len(self._buffer) <= self.maximum:
                return
            self._truncated = True
            self._head.extend(self._buffer[: self.maximum])
            self._tail.extend(self._buffer[-self.maximum :])
            self._buffer.clear()
            return
        self._tail.extend(chunk)
        if len(self._tail) > self.maximum:
            del self._tail[: -self.maximum]

    def render(self) -> bytes:
        if not self._truncated:
            return bytes(self._buffer)
        marker = (
            "\n... <sonus-flutter-run-log-truncated "
            f"original_bytes={self.total} max_bytes={self.maximum}> ...\n"
        ).encode("utf-8")
        payload_budget = self.maximum - len(marker)
        if payload_budget <= 0:
            raise ValueError("max log bytes is too small for truncation metadata")
        head_budget = payload_budget // 2
        tail_budget = payload_budget - head_budget
        output = (
            utf8_prefix(bytes(self._head), head_budget)
            + marker
            + utf8_suffix(bytes(self._tail), tail_budget)
        )
        if len(output) > self.maximum:
            output = output[: self.maximum].decode(
                "utf-8", errors="ignore"
            ).encode("utf-8")
        return output

    def write_atomic(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                prefix=f".{path.name}.",
                dir=path.parent,
                delete=False,
            ) as handle:
                temporary = Path(handle.name)
                handle.write(self.render())
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


@dataclass(frozen=True)
class DriverResult:
    passed: bool
    ready: bool
    hold_completed: bool
    quit_requested: bool
    premature_exit: bool
    failure_marker_seen: bool
    timed_out: bool
    quit_timed_out: bool
    return_code: int
    log_bytes: int


def emit(clean: str, output: TextIO, retained: BoundedLog) -> None:
    output.write(clean)
    output.flush()
    retained.feed(clean)


def terminate_bounded(process: subprocess.Popen[bytes]) -> int:
    if process.poll() is not None:
        return int(process.returncode)
    process.terminate()
    try:
        return int(process.wait(timeout=10))
    except subprocess.TimeoutExpired:
        process.kill()
        return int(process.wait(timeout=10))


def run_driver(
    command: Sequence[str],
    log_path: Path,
    timeout_seconds: float,
    hold_seconds: float,
    max_log_bytes: int = DEFAULT_MAX_LOG_BYTES,
    quit_timeout_seconds: float = DEFAULT_QUIT_TIMEOUT_SECONDS,
    output: TextIO = sys.stdout,
) -> DriverResult:
    if not command:
        raise ValueError("a flutter command is required")
    if timeout_seconds <= 0 or hold_seconds <= 0 or quit_timeout_seconds <= 0:
        raise ValueError("timeouts and hold duration must be positive")

    retained = BoundedLog(max_log_bytes)
    process = subprocess.Popen(
        list(command),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    assert process.stdout is not None
    assert process.stdin is not None

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""

    started = time.monotonic()
    ready_at: float | None = None
    quit_at: float | None = None
    quit_requested = False
    hold_completed = False
    premature_exit = False
    failure_marker_seen = False
    timed_out = False
    quit_timed_out = False

    def consume(decoded: str, *, final: bool = False) -> None:
        nonlocal pending, ready_at, failure_marker_seen
        pending += decoded
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            line += "\n"
            if any(marker in line for marker in READINESS_MARKERS) and ready_at is None:
                ready_at = time.monotonic()
            if any(marker in line for marker in FAILURE_MARKERS):
                failure_marker_seen = True
            emit(sanitize(line), output, retained)
        if final and pending:
            line = pending
            pending = ""
            if any(marker in line for marker in READINESS_MARKERS) and ready_at is None:
                ready_at = time.monotonic()
            if any(marker in line for marker in FAILURE_MARKERS):
                failure_marker_seen = True
            emit(sanitize(line), output, retained)

    try:
        while True:
            return_code = process.poll()
            now = time.monotonic()
            if return_code is not None:
                if not hold_completed:
                    premature_exit = True
                break
            if not quit_requested and now - started > timeout_seconds:
                timed_out = True
                emit("device_lab_timeout=true\n", output, retained)
                terminate_bounded(process)
                break
            if (
                ready_at is not None
                and not quit_requested
                and now - ready_at >= hold_seconds
            ):
                try:
                    process.stdin.write(b"q\n")
                    process.stdin.flush()
                except (BrokenPipeError, OSError):
                    premature_exit = True
                    terminate_bounded(process)
                    break
                quit_requested = True
                hold_completed = True
                quit_at = now
            if (
                quit_requested
                and quit_at is not None
                and now - quit_at > quit_timeout_seconds
            ):
                quit_timed_out = True
                emit("device_lab_quit_timeout=true\n", output, retained)
                terminate_bounded(process)
                break

            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), READ_CHUNK_BYTES)
                if not chunk:
                    try:
                        selector.unregister(key.fileobj)
                    except KeyError:
                        pass
                    continue
                consume(decoder.decode(chunk))

        # The process is now complete or has been terminated. Drain bytes that
        # were written immediately before exit and flush the UTF-8 decoder.
        while True:
            chunk = os.read(process.stdout.fileno(), READ_CHUNK_BYTES)
            if not chunk:
                break
            consume(decoder.decode(chunk))
        consume(decoder.decode(b"", final=True), final=True)
        return_code = int(process.wait())
    finally:
        selector.close()
        process.stdin.close()
        process.stdout.close()

    ready = ready_at is not None
    passed = (
        ready
        and hold_completed
        and quit_requested
        and not premature_exit
        and not failure_marker_seen
        and not timed_out
        and not quit_timed_out
        and return_code in (0, -15)
    )
    diagnostics = (
        f"device_lab_ready={str(ready).lower()}\n"
        f"hold_completed={str(hold_completed).lower()}\n"
        f"quit_requested={str(quit_requested).lower()}\n"
        f"premature_exit={str(premature_exit).lower()}\n"
        f"failure_marker_seen={str(failure_marker_seen).lower()}\n"
        f"device_lab_timed_out={str(timed_out).lower()}\n"
        f"device_lab_quit_timed_out={str(quit_timed_out).lower()}\n"
        f"flutter_run_return_code={return_code}\n"
    )
    emit(diagnostics, output, retained)
    retained.write_atomic(log_path)

    return DriverResult(
        passed=passed,
        ready=ready,
        hold_completed=hold_completed,
        quit_requested=quit_requested,
        premature_exit=premature_exit,
        failure_marker_seen=failure_marker_seen,
        timed_out=timed_out,
        quit_timed_out=quit_timed_out,
        return_code=return_code,
        log_bytes=len(retained.render()),
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("--hold-seconds", required=True, type=float)
    parser.add_argument("--max-log-bytes", type=int, default=DEFAULT_MAX_LOG_BYTES)
    parser.add_argument(
        "--quit-timeout-seconds",
        type=float,
        default=DEFAULT_QUIT_TIMEOUT_SECONDS,
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    return args


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    result = run_driver(
        command=args.command,
        log_path=args.log,
        timeout_seconds=args.timeout_seconds,
        hold_seconds=args.hold_seconds,
        max_log_bytes=args.max_log_bytes,
        quit_timeout_seconds=args.quit_timeout_seconds,
    )
    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
