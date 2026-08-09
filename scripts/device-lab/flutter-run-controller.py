#!/usr/bin/env python3
"""Bound a Flutter device run until readiness, then quit and retain safe logs."""

from __future__ import annotations

import argparse
import codecs
import importlib.util
import os
import re
import selectors
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

READY_MARKERS = (
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
)
PHYSICAL_IPHONE_NAME = re.compile(r"(?i)\b(on|for)\s+[^\n]+?\s+iPhone\b")
READ_BYTES = 64 * 1024


def load_policy(path: Path) -> Callable[[str], tuple[str, set[str]]]:
    spec = importlib.util.spec_from_file_location("sonus_evidence_policy", path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot load evidence policy: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    sanitize = getattr(module, "sanitize_text", None)
    if not callable(sanitize):
        raise ValueError(f"evidence policy does not expose sanitize_text: {path}")
    return sanitize


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=float, required=True)
    parser.add_argument("--hold-seconds", type=float, required=True)
    parser.add_argument("--quit-timeout-seconds", type=float, default=30.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("a child command is required after --")
    for name in ("timeout_seconds", "hold_seconds", "quit_timeout_seconds"):
        if getattr(args, name) <= 0:
            parser.error(f"--{name.replace('_', '-')} must be positive")
    return args


def terminate_bounded(process: subprocess.Popen[bytes], seconds: float = 5.0) -> int:
    if process.poll() is None:
        process.terminate()
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        process.kill()
        return process.wait(timeout=seconds)


def run(args: argparse.Namespace) -> int:
    sanitize_text = load_policy(args.policy)
    args.log.parent.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        args.command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    fd = process.stdout.fileno()
    os.set_blocking(fd, False)
    selector = selectors.DefaultSelector()
    selector.register(fd, selectors.EVENT_READ)
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    pending = ""
    started = time.monotonic()
    ready_at: float | None = None
    quit_sent_at: float | None = None
    failed = False
    timed_out = False

    def emit(line: str, log: object) -> None:
        nonlocal ready_at, failed
        if ready_at is None and any(marker in line for marker in READY_MARKERS):
            ready_at = time.monotonic()
        if any(marker in line for marker in FAILURE_MARKERS):
            failed = True
        clean, _ = sanitize_text(line)
        clean = PHYSICAL_IPHONE_NAME.sub(r"\1 <physical-iPhone>", clean)
        sys.stdout.write(clean)
        sys.stdout.flush()
        log.write(clean)
        log.flush()

    def consume(chunk: bytes, log: object, *, final: bool = False) -> None:
        nonlocal pending
        pending += decoder.decode(chunk, final=final)
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            emit(line + "\n", log)
        if final and pending:
            emit(pending, log)
            pending = ""

    with args.log.open("w", encoding="utf-8") as log:
        while True:
            now = time.monotonic()
            if process.poll() is None and now - started > args.timeout_seconds:
                log.write("device_lab_timeout=true\n")
                log.flush()
                failed = True
                timed_out = True
                terminate_bounded(process)
            elif (
                process.poll() is None
                and ready_at is not None
                and quit_sent_at is None
                and now - ready_at >= args.hold_seconds
            ):
                try:
                    process.stdin.write(b"q\n")
                    process.stdin.flush()
                except (BrokenPipeError, OSError):
                    failed = True
                quit_sent_at = now
            elif (
                process.poll() is None
                and quit_sent_at is not None
                and now - quit_sent_at > args.quit_timeout_seconds
            ):
                log.write("device_lab_quit_timeout=true\n")
                log.flush()
                failed = True
                terminate_bounded(process)

            for _, _ in selector.select(timeout=0.1):
                try:
                    chunk = os.read(fd, READ_BYTES)
                except BlockingIOError:
                    continue
                if chunk:
                    consume(chunk, log)
                else:
                    try:
                        selector.unregister(fd)
                    except KeyError:
                        pass

            if process.poll() is not None:
                os.set_blocking(fd, True)
                remaining = process.stdout.read() or b""
                consume(remaining, log, final=True)
                break

        return_code = process.wait(timeout=5)

    held_ready = ready_at is not None and quit_sent_at is not None
    if timed_out or not held_ready or return_code not in (0, -15):
        failed = True
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    return run(parse_args(argv))


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(f"flutter-run-controller: {error}", file=sys.stderr)
        raise SystemExit(2)
