#!/usr/bin/env python3
"""Stream one command with a bounded process-group lifetime."""

from __future__ import annotations

import argparse
import io
import os
import selectors
import signal
import subprocess
import sys
import time
from typing import BinaryIO, Sequence

READ_CHUNK_BYTES = 64 * 1024
DEFAULT_GRACE_SECONDS = 5.0
TIMEOUT_EXIT_CODE = 124


def signal_group(process: subprocess.Popen[bytes], sig: signal.Signals) -> None:
    try:
        os.killpg(process.pid, sig)
    except (ProcessLookupError, PermissionError):
        try:
            process.send_signal(sig)
        except ProcessLookupError:
            pass


def stream_command(
    command: Sequence[str],
    *,
    timeout_seconds: float,
    grace_seconds: float,
    sink: BinaryIO,
    stderr_mode: str,
) -> tuple[int, bool, bool]:
    if not command:
        raise ValueError("a command is required after --")
    if timeout_seconds <= 0:
        raise ValueError("timeout-seconds must be positive")
    if grace_seconds < 0:
        raise ValueError("grace-seconds may not be negative")
    if stderr_mode not in {"inherit", "discard", "merge"}:
        raise ValueError(f"unsupported stderr mode: {stderr_mode}")

    stderr: int | None
    if stderr_mode == "discard":
        stderr = subprocess.DEVNULL
    elif stderr_mode == "merge":
        stderr = subprocess.STDOUT
    else:
        stderr = None

    process = subprocess.Popen(
        list(command),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=stderr,
        bufsize=0,
        start_new_session=True,
    )
    assert process.stdout is not None
    output_fd = process.stdout.fileno()
    os.set_blocking(output_fd, False)
    selector = selectors.DefaultSelector()
    selector.register(output_fd, selectors.EVENT_READ)

    started = time.monotonic()
    terminate_at: float | None = None
    timed_out = False
    killed = False
    eof = False

    def emit(chunk: bytes) -> None:
        sink.write(chunk)
        sink.flush()

    try:
        while True:
            now = time.monotonic()
            return_code = process.poll()
            if return_code is None and not timed_out and now - started >= timeout_seconds:
                timed_out = True
                terminate_at = now
                signal_group(process, signal.SIGTERM)
            if (
                return_code is None
                and timed_out
                and terminate_at is not None
                and not killed
                and now - terminate_at >= grace_seconds
            ):
                killed = True
                signal_group(process, signal.SIGKILL)

            for key, _ in selector.select(timeout=0.1):
                try:
                    chunk = os.read(key.fd, READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                if chunk:
                    emit(chunk)
                else:
                    eof = True
                    try:
                        selector.unregister(key.fd)
                    except KeyError:
                        pass

            if process.poll() is not None and not eof:
                while True:
                    try:
                        chunk = os.read(output_fd, READ_CHUNK_BYTES)
                    except BlockingIOError:
                        break
                    if not chunk:
                        eof = True
                        try:
                            selector.unregister(output_fd)
                        except KeyError:
                            pass
                        break
                    emit(chunk)

            if process.poll() is not None and eof:
                break
    except BaseException:
        if process.poll() is None:
            signal_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=max(grace_seconds, 0.1))
            except subprocess.TimeoutExpired:
                signal_group(process, signal.SIGKILL)
                process.wait(timeout=5)
        raise
    finally:
        selector.close()

    return_code = process.wait(timeout=1)
    return (TIMEOUT_EXIT_CODE if timed_out else return_code, timed_out, killed)


def self_test() -> None:
    sink = io.BytesIO()
    code, timed_out, killed = stream_command(
        [sys.executable, "-u", "-c", "print('alpha'); print('omega')"],
        timeout_seconds=5,
        grace_seconds=0.2,
        sink=sink,
        stderr_mode="discard",
    )
    assert code == 0
    assert timed_out is False
    assert killed is False
    assert sink.getvalue() == b"alpha\nomega\n"

    nonzero_sink = io.BytesIO()
    code, timed_out, _ = stream_command(
        [sys.executable, "-u", "-c", "print('before-exit'); raise SystemExit(7)"],
        timeout_seconds=5,
        grace_seconds=0.2,
        sink=nonzero_sink,
        stderr_mode="discard",
    )
    assert code == 7
    assert timed_out is False
    assert nonzero_sink.getvalue() == b"before-exit\n"

    timeout_sink = io.BytesIO()
    started = time.monotonic()
    code, timed_out, _ = stream_command(
        [
            sys.executable,
            "-u",
            "-c",
            "import time; print('before-timeout', flush=True); time.sleep(30)",
        ],
        timeout_seconds=0.5,
        grace_seconds=0.2,
        sink=timeout_sink,
        stderr_mode="discard",
    )
    elapsed = time.monotonic() - started
    assert code == TIMEOUT_EXIT_CODE
    assert timed_out is True
    assert elapsed < 3, elapsed
    assert b"before-timeout\n" in timeout_sink.getvalue()

    merge_sink = io.BytesIO()
    code, _, _ = stream_command(
        [
            sys.executable,
            "-u",
            "-c",
            "import sys; print('stdout'); print('stderr', file=sys.stderr)",
        ],
        timeout_seconds=5,
        grace_seconds=0.2,
        sink=merge_sink,
        stderr_mode="merge",
    )
    assert code == 0
    merged = merge_sink.getvalue()
    assert b"stdout\n" in merged and b"stderr\n" in merged

    class ChunkSink(io.BytesIO):
        def write(self, data: bytes) -> int:
            assert len(data) <= READ_CHUNK_BYTES
            return super().write(data)

    large_sink = ChunkSink()
    code, _, _ = stream_command(
        [sys.executable, "-u", "-c", "import sys; sys.stdout.write('x' * 200000)"],
        timeout_seconds=5,
        grace_seconds=0.2,
        sink=large_sink,
        stderr_mode="discard",
    )
    assert code == 0
    assert len(large_sink.getvalue()) == 200000

    print(
        "Command timeout self-test passed: success + nonzero + bounded timeout + "
        "stderr mode + chunked streaming"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-seconds", type=float, default=120)
    parser.add_argument("--grace-seconds", type=float, default=DEFAULT_GRACE_SECONDS)
    parser.add_argument(
        "--stderr",
        choices=("inherit", "discard", "merge"),
        default="inherit",
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    code, timed_out, killed = stream_command(
        command,
        timeout_seconds=args.timeout_seconds,
        grace_seconds=args.grace_seconds,
        sink=sys.stdout.buffer,
        stderr_mode=args.stderr,
    )
    if timed_out:
        print(
            "run-with-timeout: command exceeded "
            f"{args.timeout_seconds:g}s; process_group_killed={str(killed).lower()}",
            file=sys.stderr,
        )
    return code


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"run-with-timeout: {error}", file=sys.stderr)
        raise SystemExit(2)
