#!/usr/bin/env python3
"""Bound a UTF-8 log stream while preserving startup and terminal context."""

from __future__ import annotations

import argparse
import sys

DEFAULT_MAX_BYTES = 512 * 1024
MARKER_TEMPLATE = "\n... <sonus-log-truncated original_bytes={original} max_bytes={maximum}> ...\n"


def utf8_prefix(data: bytes, limit: int) -> bytes:
    return data[:limit].decode("utf-8", errors="ignore").encode("utf-8")


def utf8_suffix(data: bytes, limit: int) -> bytes:
    return data[-limit:].decode("utf-8", errors="ignore").encode("utf-8")


def bound(data: bytes, maximum: int) -> tuple[bytes, bool]:
    if maximum < 256:
        raise ValueError("max-bytes must be at least 256")
    normalized = data.decode("utf-8", errors="replace").encode("utf-8")
    if len(normalized) <= maximum:
        return normalized, False

    marker = MARKER_TEMPLATE.format(
        original=len(normalized), maximum=maximum
    ).encode("utf-8")
    payload_budget = maximum - len(marker)
    if payload_budget <= 0:
        raise ValueError("max-bytes is too small for the truncation marker")
    head_budget = payload_budget // 2
    tail_budget = payload_budget - head_budget
    head = utf8_prefix(normalized, head_budget)
    tail = utf8_suffix(normalized, tail_budget)
    output = head + marker + tail
    if len(output) > maximum:
        output = output[:maximum].decode("utf-8", errors="ignore").encode("utf-8")
    return output, True


def self_test() -> None:
    small = b"startup\nready\n"
    bounded, truncated = bound(small, 512)
    assert bounded == small
    assert truncated is False

    original = (b"START\n" + b"middle\n" * 300 + b"END\n")
    bounded, truncated = bound(original, 512)
    assert truncated is True
    assert len(bounded) <= 512
    text = bounded.decode("utf-8")
    assert text.startswith("START\n")
    assert text.endswith("END\n")
    assert "sonus-log-truncated" in text
    assert "original_bytes=" in text

    unicode_input = ("α" * 600 + "terminal✓\n").encode("utf-8")
    bounded, truncated = bound(unicode_input, 513)
    assert truncated is True
    assert len(bounded) <= 513
    bounded.decode("utf-8")
    assert "terminal✓" in bounded.decode("utf-8")
    print("Bounded log self-test passed: passthrough + head/tail + UTF-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    output, _ = bound(sys.stdin.buffer.read(), args.max_bytes)
    sys.stdout.buffer.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
