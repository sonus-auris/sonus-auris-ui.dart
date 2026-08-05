#!/usr/bin/env python3
"""Retain bounded simulator logs while scanning the complete stream for crashes.

The reducer never consumes stdin with an unbounded read. It keeps startup and
terminal windows only, but crash detection observes every input chunk. The JSON
status sidecar contains pattern identifiers and byte counts, never raw log text.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import BinaryIO, Iterable

DEFAULT_MAX_BYTES = 512 * 1024
READ_CHUNK_BYTES = 64 * 1024
SCAN_OVERLAP_BYTES = 16 * 1024
MARKER_TEMPLATE = (
    "\n... <sonus-log-truncated original_bytes={original} "
    "max_bytes={maximum}> ...\n"
)
SCHEMA = "sonus-auris-log-evidence/v1"

# Keep identifiers stable so CI and artifact auditors can reason about status
# without retaining the matching log line itself.
FATAL_PATTERNS: tuple[tuple[str, re.Pattern[bytes]], ...] = (
    (
        "uncaught-exception",
        re.compile(rb"Terminating app due to uncaught exception", re.IGNORECASE),
    ),
    ("fatal-error", re.compile(rb"Fatal error", re.IGNORECASE)),
    ("exc-crash", re.compile(rb"EXC_CRASH", re.IGNORECASE)),
    ("sigabrt", re.compile(rb"SIGABRT", re.IGNORECASE)),
    (
        "lost-device-connection",
        re.compile(rb"Lost connection to device", re.IGNORECASE),
    ),
    (
        "library-not-loaded",
        re.compile(rb"Library not loaded", re.IGNORECASE),
    ),
    (
        "dyld-reason",
        re.compile(rb"dyld[^\r\n]{0,8192}Reason", re.IGNORECASE),
    ),
)


def utf8_prefix(data: bytes, limit: int) -> bytes:
    return data[:limit].decode("utf-8", errors="ignore").encode("utf-8")


def utf8_suffix(data: bytes, limit: int) -> bytes:
    return data[-limit:].decode("utf-8", errors="ignore").encode("utf-8")


def truncated_output(head: bytes, tail: bytes, original: int, maximum: int) -> bytes:
    marker = MARKER_TEMPLATE.format(
        original=original,
        maximum=maximum,
    ).encode("utf-8")
    payload_budget = maximum - len(marker)
    if payload_budget <= 0:
        raise ValueError("max-bytes is too small for the truncation marker")
    head_budget = payload_budget // 2
    tail_budget = payload_budget - head_budget
    output = utf8_prefix(head, head_budget) + marker + utf8_suffix(tail, tail_budget)
    if len(output) > maximum:
        output = output[:maximum].decode("utf-8", errors="ignore").encode("utf-8")
    return output


def scan_patterns(window: bytes, observed: set[str]) -> None:
    for name, pattern in FATAL_PATTERNS:
        if name not in observed and pattern.search(window):
            observed.add(name)


def reduce_and_scan_stream(
    source: BinaryIO,
    sink: BinaryIO,
    maximum: int,
    *,
    chunk_bytes: int = READ_CHUNK_BYTES,
) -> dict[str, object]:
    """Copy bounded head/tail evidence and scan every input byte for fatal signs."""

    if maximum < 1024:
        raise ValueError("max-bytes must be at least 1024")
    if chunk_bytes < 1:
        raise ValueError("chunk-bytes must be positive")

    total = 0
    buffered = bytearray()
    head = bytearray()
    tail = bytearray()
    overlap = b""
    observed: set[str] = set()
    truncated = False

    while True:
        chunk = source.read(chunk_bytes)
        if not chunk:
            break
        total += len(chunk)

        scan_window = overlap + chunk
        scan_patterns(scan_window, observed)
        overlap = scan_window[-SCAN_OVERLAP_BYTES:]

        if not truncated:
            buffered.extend(chunk)
            if len(buffered) <= maximum:
                continue
            truncated = True
            head.extend(buffered[:maximum])
            tail.extend(buffered[-maximum:])
            buffered.clear()
            continue

        tail.extend(chunk)
        if len(tail) > maximum:
            del tail[:-maximum]

    if truncated:
        output = truncated_output(bytes(head), bytes(tail), total, maximum)
    else:
        output = bytes(buffered).decode("utf-8", errors="replace").encode("utf-8")
        if len(output) > maximum:
            # Invalid UTF-8 replacement can expand a byte stream. Preserve the
            # same bounded head/tail contract even in that adversarial case.
            output = truncated_output(output, output, total, maximum)
            truncated = True

    sink.write(output)
    return {
        "schema": SCHEMA,
        "fatal_observed": bool(observed),
        "fatal_patterns": sorted(observed),
        "original_bytes": total,
        "retained_bytes": len(output),
        "truncated": truncated,
        "max_bytes": maximum,
        "raw_log_embedded_in_status": False,
        "full_stream_scanned": True,
    }


def write_status(path: Path, status: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as handle:
        json.dump(status, handle, sort_keys=True, indent=2)
        handle.write("\n")
        temp_name = handle.name
    os.replace(temp_name, path)


def run_case(payload: bytes, maximum: int, chunk_bytes: int) -> tuple[bytes, dict[str, object]]:
    source = io.BytesIO(payload)
    sink = io.BytesIO()
    status = reduce_and_scan_stream(
        source,
        sink,
        maximum,
        chunk_bytes=chunk_bytes,
    )
    return sink.getvalue(), status


def self_test() -> None:
    output, status = run_case(b"startup\nready\n", 1024, 17)
    assert output == b"startup\nready\n"
    assert status["truncated"] is False
    assert status["fatal_observed"] is False

    original = b"START\n" + b"middle\n" * 3000 + b"END\n"
    output, status = run_case(original, 1024, 137)
    assert status["truncated"] is True
    assert len(output) <= 1024
    assert output.startswith(b"START\n")
    assert output.endswith(b"END\n")
    assert b"sonus-log-truncated" in output

    # The fatal line is deliberately outside both retained windows. The
    # sidecar must still fail closed after scanning the complete stream.
    hidden_fatal = (
        b"BOOT\n"
        + b"head-noise\n" * 2000
        + b"Terminating app due to uncaught exception NSInvalidArgumentException\n"
        + b"tail-noise\n" * 2000
        + b"SHUTDOWN\n"
    )
    output, status = run_case(hidden_fatal, 1024, 113)
    assert status["fatal_observed"] is True
    assert "uncaught-exception" in status["fatal_patterns"]
    assert b"uncaught exception" not in output.lower()

    # Exercise a signature split exactly across read chunks and the overlap.
    split = b"A" * 31 + b"Library not loaded" + b"\n"
    output, status = run_case(split, 1024, 37)
    assert status["fatal_observed"] is True
    assert "library-not-loaded" in status["fatal_patterns"]

    unicode_input = ("α" * 5000 + "terminal✓\n").encode("utf-8")
    output, status = run_case(unicode_input, 1025, 129)
    assert status["truncated"] is True
    assert len(output) <= 1025
    assert "terminal✓" in output.decode("utf-8")

    class ChunkOnly(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            assert size > 0, "log reducer attempted an unbounded read"
            return super().read(size)

    source = ChunkOnly(b"BOOT\n" + b"event\n" * 10000 + b"SHUTDOWN\n")
    sink = io.BytesIO()
    status = reduce_and_scan_stream(source, sink, 2048, chunk_bytes=211)
    assert status["original_bytes"] > 2048
    assert status["retained_bytes"] <= 2048
    assert status["full_stream_scanned"] is True

    with tempfile.TemporaryDirectory() as directory:
        status_path = Path(directory) / "status.json"
        write_status(status_path, status)
        decoded = json.loads(status_path.read_text(encoding="utf-8"))
        assert decoded == status
        assert "BOOT" not in status_path.read_text(encoding="utf-8")

    print(
        "iOS simulator log-evidence self-test passed: passthrough + bounded "
        "head/tail + UTF-8 + full-stream hidden-fatal scan + atomic sidecar"
    )


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--status-file", type=Path)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(list(argv))


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if args.status_file is None:
        raise SystemExit("--status-file is required unless --self-test is used")
    status = reduce_and_scan_stream(sys.stdin.buffer, sys.stdout.buffer, args.max_bytes)
    write_status(args.status_file, status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
