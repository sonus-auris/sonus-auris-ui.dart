#!/usr/bin/env python3
"""Bound a UTF-8 log stream while preserving startup and terminal context."""

from __future__ import annotations

import argparse
import io
import sys
from typing import BinaryIO

DEFAULT_MAX_BYTES = 512 * 1024
READ_CHUNK_BYTES = 64 * 1024
MARKER_TEMPLATE = (
    "\n... <sonus-log-truncated original_bytes={original} "
    "max_bytes={maximum}> ...\n"
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


def bound(data: bytes, maximum: int) -> tuple[bytes, bool]:
    if maximum < 256:
        raise ValueError("max-bytes must be at least 256")
    normalized = data.decode("utf-8", errors="replace").encode("utf-8")
    if len(normalized) <= maximum:
        return normalized, False
    return truncated_output(normalized, normalized, len(normalized), maximum), True


def bound_stream(
    source: BinaryIO,
    sink: BinaryIO,
    maximum: int,
    *,
    chunk_bytes: int = READ_CHUNK_BYTES,
) -> tuple[int, bool, int]:
    """Copy a stream with output and memory bounded by ``maximum``.

    At most one ``maximum``-byte startup window and one ``maximum``-byte tail
    window are retained. The input is never consumed with an unbounded read.
    """

    if maximum < 256:
        raise ValueError("max-bytes must be at least 256")
    if chunk_bytes < 1:
        raise ValueError("chunk-bytes must be positive")

    total = 0
    buffered = bytearray()
    head = bytearray()
    tail = bytearray()
    truncated = False

    while True:
        chunk = source.read(chunk_bytes)
        if not chunk:
            break
        total += len(chunk)
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

    if not truncated:
        output, normalized_truncated = bound(bytes(buffered), maximum)
        sink.write(output)
        return len(output), normalized_truncated, total

    output = truncated_output(bytes(head), bytes(tail), total, maximum)
    sink.write(output)
    return len(output), True, total


def self_test() -> None:
    small = b"startup\nready\n"
    output, truncated = bound(small, 512)
    assert output == small and truncated is False

    original = b"START\n" + b"middle\n" * 300 + b"END\n"
    output, truncated = bound(original, 512)
    assert truncated is True
    assert len(output) <= 512
    decoded = output.decode("utf-8")
    assert decoded.startswith("START\n")
    assert decoded.endswith("END\n")
    assert "sonus-log-truncated" in decoded

    unicode_input = ("α" * 600 + "terminal✓\n").encode("utf-8")
    output, truncated = bound(unicode_input, 513)
    assert truncated is True
    assert len(output) <= 513
    assert "terminal✓" in output.decode("utf-8")

    class ChunkOnly(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            assert size > 0, "stream reducer attempted an unbounded read"
            return super().read(size)

    source = ChunkOnly(b"BOOT\n" + b"event\n" * 10000 + b"SHUTDOWN\n")
    sink = io.BytesIO()
    written, truncated, original_bytes = bound_stream(
        source,
        sink,
        1024,
        chunk_bytes=137,
    )
    streamed = sink.getvalue()
    assert truncated is True
    assert written == len(streamed) <= 1024
    assert original_bytes > 1024
    assert streamed.startswith(b"BOOT\n")
    assert streamed.endswith(b"SHUTDOWN\n")
    assert b"sonus-log-truncated" in streamed

    print(
        "Bounded log self-test passed: passthrough + head/tail + UTF-8 + "
        "chunked bounded-memory stream"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    bound_stream(sys.stdin.buffer, sys.stdout.buffer, args.max_bytes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
