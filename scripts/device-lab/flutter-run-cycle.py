#!/usr/bin/env python3
"""Run one bounded Flutter device cycle and drain terminal output completely."""

from __future__ import annotations

import argparse
import codecs
import io
import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import BinaryIO, Sequence

READ_CHUNK_BYTES = 64 * 1024
POST_QUIT_EXIT_SECONDS = 30.0
TERMINATE_GRACE_SECONDS = 10.0
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
    "Terminating app due to uncaught exception",
    "Unhandled Exception",
    "Fatal error",
    "EXC_CRASH",
    "SIGABRT",
    "Library not loaded",
)
SCAN_OVERLAP_CHARS = max(len(marker) for marker in READY_MARKERS + FAILURE_MARKERS) - 1


def signal_process_group(process: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except (ProcessLookupError, PermissionError):
        try:
            process.send_signal(sig)
        except ProcessLookupError:
            pass


def write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_cycle(
    command: Sequence[str],
    *,
    timeout_seconds: float,
    hold_seconds: float,
    sink: BinaryIO,
) -> dict[str, object]:
    if not command:
        raise ValueError("a Flutter command is required after --")
    if timeout_seconds <= 0:
        raise ValueError("timeout-seconds must be positive")
    if hold_seconds < 0:
        raise ValueError("ready-hold-seconds may not be negative")

    process = subprocess.Popen(
        list(command),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        start_new_session=True,
    )
    assert process.stdin is not None
    assert process.stdout is not None

    output_fd = process.stdout.fileno()
    os.set_blocking(output_fd, False)
    selector = selectors.DefaultSelector()
    selector.register(output_fd, selectors.EVENT_READ)

    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    overlap = ""
    started = time.monotonic()
    ready_at: float | None = None
    ready_marker: str | None = None
    quit_sent_at: float | None = None
    terminate_sent_at: float | None = None
    kill_sent = False
    timed_out = False
    eof_observed = False
    output_bytes = 0
    fatal_markers: set[str] = set()
    monitor_errors: list[str] = []

    def inspect(decoded: str) -> None:
        nonlocal overlap, ready_at, ready_marker
        combined = overlap + decoded
        if ready_at is None:
            for marker in READY_MARKERS:
                if marker in combined:
                    ready_at = time.monotonic()
                    ready_marker = marker
                    break
        for marker in FAILURE_MARKERS:
            if marker in combined:
                fatal_markers.add(marker)
        overlap = combined[-SCAN_OVERLAP_CHARS:]

    def emit(chunk: bytes) -> None:
        nonlocal output_bytes
        output_bytes += len(chunk)
        sink.write(chunk)
        sink.flush()
        inspect(decoder.decode(chunk, final=False))

    try:
        while True:
            now = time.monotonic()
            return_code = process.poll()

            if (
                ready_at is not None
                and quit_sent_at is None
                and now - ready_at >= hold_seconds
                and return_code is None
            ):
                try:
                    process.stdin.write(b"q\n")
                    process.stdin.flush()
                    quit_sent_at = now
                except (BrokenPipeError, OSError):
                    monitor_errors.append("flutter-stdin-closed-before-quit")

            if return_code is None and now - started > timeout_seconds:
                timed_out = True
                if terminate_sent_at is None:
                    terminate_sent_at = now
                    signal_process_group(process, signal.SIGTERM)

            if (
                return_code is None
                and quit_sent_at is not None
                and now - quit_sent_at > POST_QUIT_EXIT_SECONDS
                and terminate_sent_at is None
            ):
                monitor_errors.append("flutter-did-not-exit-after-quit")
                terminate_sent_at = now
                signal_process_group(process, signal.SIGTERM)

            if (
                return_code is None
                and terminate_sent_at is not None
                and now - terminate_sent_at > TERMINATE_GRACE_SECONDS
                and not kill_sent
            ):
                kill_sent = True
                signal_process_group(process, signal.SIGKILL)

            for key, _ in selector.select(timeout=0.2):
                try:
                    chunk = os.read(key.fd, READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                if chunk:
                    emit(chunk)
                else:
                    eof_observed = True
                    try:
                        selector.unregister(key.fd)
                    except KeyError:
                        pass

            # A process can exit between select calls with bytes still buffered.
            # Continue non-blocking reads until the pipe reports EOF.
            if process.poll() is not None and not eof_observed:
                while True:
                    try:
                        chunk = os.read(output_fd, READ_CHUNK_BYTES)
                    except BlockingIOError:
                        break
                    if not chunk:
                        eof_observed = True
                        try:
                            selector.unregister(output_fd)
                        except KeyError:
                            pass
                        break
                    emit(chunk)

            if process.poll() is not None and eof_observed:
                break
    except BaseException:
        if process.poll() is None:
            signal_process_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=TERMINATE_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                signal_process_group(process, signal.SIGKILL)
                process.wait(timeout=TERMINATE_GRACE_SECONDS)
        raise
    finally:
        selector.close()
        try:
            process.stdin.close()
        except OSError:
            pass

    inspect(decoder.decode(b"", final=True))
    return_code = process.wait(timeout=1)
    duration = time.monotonic() - started
    ready_hold_completed = (
        ready_at is not None
        and quit_sent_at is not None
        and quit_sent_at - ready_at >= hold_seconds
    )
    passed = (
        ready_at is not None
        and ready_hold_completed
        and quit_sent_at is not None
        and return_code == 0
        and not timed_out
        and not fatal_markers
        and not monitor_errors
        and eof_observed
    )
    return {
        "schema": "sonus-auris-flutter-run-cycle/v1",
        "status": "passed" if passed else "failed",
        "ready_observed": ready_at is not None,
        "ready_marker": ready_marker,
        "ready_hold_completed": ready_hold_completed,
        "quit_sent": quit_sent_at is not None,
        "timed_out": timed_out,
        "return_code": return_code,
        "terminal_output_drained": eof_observed,
        "output_bytes": output_bytes,
        "duration_millis": int(duration * 1000),
        "fatal_markers": sorted(fatal_markers),
        "monitor_errors": monitor_errors,
        "termination_signal_sent": terminate_sent_at is not None,
        "kill_signal_sent": kill_sent,
    }


def self_test() -> None:
    success_program = r'''
import sys
print("boot")
print("Flutter run key commands")
sys.stdout.flush()
assert sys.stdin.readline().strip() == "q"
print("terminal-output-after-q")
sys.stdout.flush()
'''
    success_sink = io.BytesIO()
    success = run_cycle(
        [sys.executable, "-u", "-c", success_program],
        timeout_seconds=5,
        hold_seconds=0.05,
        sink=success_sink,
    )
    assert success["status"] == "passed", success
    assert success["terminal_output_drained"] is True
    assert b"terminal-output-after-q" in success_sink.getvalue()

    fatal_program = r'''
import sys
print("Flutter run key commands")
sys.stdout.flush()
assert sys.stdin.readline().strip() == "q"
sys.stdout.write("Lost connection")
sys.stdout.flush()
sys.stdout.write(" to device\n")
sys.stdout.flush()
'''
    fatal_sink = io.BytesIO()
    fatal = run_cycle(
        [sys.executable, "-u", "-c", fatal_program],
        timeout_seconds=5,
        hold_seconds=0.05,
        sink=fatal_sink,
    )
    assert fatal["status"] == "failed", fatal
    assert fatal["fatal_markers"] == ["Lost connection to device"]
    assert b"Lost connection to device" in fatal_sink.getvalue()

    timeout_program = "import time; print('starting', flush=True); time.sleep(30)"
    timeout_sink = io.BytesIO()
    timeout = run_cycle(
        [sys.executable, "-u", "-c", timeout_program],
        timeout_seconds=0.2,
        hold_seconds=0,
        sink=timeout_sink,
    )
    assert timeout["status"] == "failed", timeout
    assert timeout["timed_out"] is True
    assert timeout["termination_signal_sent"] is True
    assert timeout["terminal_output_drained"] is True

    print(
        "Flutter run cycle self-test passed: ready/quit + post-quit drain + "
        "split fatal marker + timeout reaping"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=float, default=240)
    parser.add_argument("--ready-hold-seconds", type=float, default=12)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0
    if args.report is None:
        raise ValueError("--report is required unless --self-test is used")
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    report = run_cycle(
        command,
        timeout_seconds=args.timeout_seconds,
        hold_seconds=args.ready_hold_seconds,
        sink=sys.stdout.buffer,
    )
    write_report(args.report, report)
    if report["status"] != "passed":
        print(
            "flutter-run-cycle: "
            f"ready={report['ready_observed']} "
            f"return_code={report['return_code']} "
            f"fatal={','.join(report['fatal_markers']) or 'none'} "
            f"errors={','.join(report['monitor_errors']) or 'none'}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"flutter-run-cycle: {error}", file=sys.stderr)
        raise SystemExit(2)
