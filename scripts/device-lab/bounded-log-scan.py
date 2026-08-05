#!/usr/bin/env python3
"""Retain bounded log evidence while scanning the complete stream.

The reducer reads fixed-size binary chunks, preserves UTF-8 startup and terminal
windows, and reports pattern counts without retaining matching log text. It is
safe to place after ``evidence-policy.py --stream`` in a device-lab pipeline.
"""

from __future__ import annotations

import argparse
import codecs
import io
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable

DEFAULT_MAX_BYTES = 512 * 1024
READ_CHUNK_BYTES = 64 * 1024
DEFAULT_SCAN_OVERLAP_CHARS = 16 * 1024
MARKER_TEMPLATE = (
    "\n... <sonus-log-truncated input_bytes={original} "
    "max_bytes={maximum}> ...\n"
)


@dataclass(frozen=True)
class ScanPattern:
    name: str
    expression: re.Pattern[str]


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


def parse_scan_patterns(values: Iterable[str]) -> list[ScanPattern]:
    patterns: list[ScanPattern] = []
    names: set[str] = set()
    for value in values:
        name, separator, expression = value.partition("=")
        if not separator or not name or not expression:
            raise ValueError("--scan must use NAME=REGEX")
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
            raise ValueError(f"invalid scan name: {name}")
        if name in names:
            raise ValueError(f"duplicate scan name: {name}")
        names.add(name)
        patterns.append(ScanPattern(name, re.compile(expression)))
    return patterns


def scan_text(
    text: str,
    prior_overlap_chars: int,
    patterns: list[ScanPattern],
    counts: dict[str, int],
) -> None:
    for pattern in patterns:
        for match in pattern.expression.finditer(text):
            # Matches ending entirely within the overlap were counted in the
            # previous chunk. Boundary-spanning matches end in new text and are
            # counted exactly once.
            if match.end() > prior_overlap_chars:
                counts[pattern.name] += 1


def reduce_stream(
    source: BinaryIO,
    sink: BinaryIO,
    *,
    maximum: int,
    patterns: list[ScanPattern],
    scan_overlap_chars: int = DEFAULT_SCAN_OVERLAP_CHARS,
    chunk_bytes: int = READ_CHUNK_BYTES,
) -> dict[str, object]:
    if maximum < 256:
        raise ValueError("max-bytes must be at least 256")
    if chunk_bytes < 1:
        raise ValueError("chunk-bytes must be positive")
    if scan_overlap_chars < 1:
        raise ValueError("scan-overlap-chars must be positive")

    total = 0
    buffered = bytearray()
    head = bytearray()
    tail = bytearray()
    truncated = False
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    overlap = ""
    counts = {pattern.name: 0 for pattern in patterns}

    def scan_decoded(decoded: str) -> None:
        nonlocal overlap
        combined = overlap + decoded
        scan_text(combined, len(overlap), patterns, counts)
        overlap = combined[-scan_overlap_chars:]

    while True:
        chunk = source.read(chunk_bytes)
        if not chunk:
            break
        total += len(chunk)
        scan_decoded(decoder.decode(chunk, final=False))

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

    scan_decoded(decoder.decode(b"", final=True))

    if truncated:
        output = truncated_output(bytes(head), bytes(tail), total, maximum)
    else:
        output = bytes(buffered).decode("utf-8", errors="replace").encode("utf-8")
        if len(output) > maximum:
            truncated = True
            output = truncated_output(output, output, total, maximum)

    sink.write(output)
    match_total = sum(counts.values())
    return {
        "schema": "sonus-auris-bounded-log-scan/v1",
        "status": "matched" if match_total else "passed",
        "input_bytes": total,
        "output_bytes": len(output),
        "max_bytes": maximum,
        "truncated": truncated,
        "scan_overlap_chars": scan_overlap_chars,
        "full_stream_scanned": True,
        "matches_total": match_total,
        "patterns": [
            {"name": pattern.name, "matches": counts[pattern.name]}
            for pattern in patterns
        ],
    }


def write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def self_test() -> None:
    safe = parse_scan_patterns([r"fatal=Fatal error", r"crash=EXC_CRASH"])

    small_sink = io.BytesIO()
    small_report = reduce_stream(
        io.BytesIO(b"startup\nready\n"),
        small_sink,
        maximum=512,
        patterns=safe,
        chunk_bytes=3,
    )
    assert small_sink.getvalue() == b"startup\nready\n"
    assert small_report["truncated"] is False
    assert small_report["matches_total"] == 0

    # The fatal marker is deliberately outside both retained windows. The
    # complete-stream scan must still catch it even though the evidence text
    # cannot contain it.
    middle_fatal = b"BOOT\n" + b"a" * 4000 + b"Fatal error" + b"b" * 4000 + b"END\n"
    middle_sink = io.BytesIO()
    middle_report = reduce_stream(
        io.BytesIO(middle_fatal),
        middle_sink,
        maximum=512,
        patterns=safe,
        chunk_bytes=127,
    )
    middle_output = middle_sink.getvalue()
    assert len(middle_output) <= 512
    assert middle_output.startswith(b"BOOT\n")
    assert middle_output.endswith(b"END\n")
    assert b"Fatal error" not in middle_output
    assert middle_report["truncated"] is True
    assert middle_report["matches_total"] == 1
    assert middle_report["patterns"][0] == {"name": "fatal", "matches": 1}

    boundary_sink = io.BytesIO()
    boundary_report = reduce_stream(
        io.BytesIO(b"prefix-Fatal error-suffix"),
        boundary_sink,
        maximum=512,
        patterns=safe,
        scan_overlap_chars=64,
        chunk_bytes=9,
    )
    assert boundary_report["matches_total"] == 1

    unicode_input = ("α" * 600 + "terminal✓\n").encode("utf-8")
    unicode_sink = io.BytesIO()
    unicode_report = reduce_stream(
        io.BytesIO(unicode_input),
        unicode_sink,
        maximum=513,
        patterns=safe,
        chunk_bytes=11,
    )
    assert unicode_report["truncated"] is True
    assert len(unicode_sink.getvalue()) <= 513
    assert "terminal✓" in unicode_sink.getvalue().decode("utf-8")

    class ChunkOnly(io.BytesIO):
        def read(self, size: int = -1) -> bytes:
            assert size > 0, "stream reducer attempted an unbounded read"
            return super().read(size)

    chunk_sink = io.BytesIO()
    chunk_report = reduce_stream(
        ChunkOnly(b"BOOT\n" + b"event\n" * 10000 + b"SHUTDOWN\n"),
        chunk_sink,
        maximum=1024,
        patterns=safe,
        chunk_bytes=137,
    )
    assert chunk_report["full_stream_scanned"] is True
    assert chunk_report["matches_total"] == 0
    assert chunk_sink.getvalue().startswith(b"BOOT\n")
    assert chunk_sink.getvalue().endswith(b"SHUTDOWN\n")

    print(
        "Bounded log scan self-test passed: passthrough + UTF-8 + head/tail + "
        "discarded-middle fatal + boundary scan + chunk-only reads"
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument("--scan-overlap-chars", type=int, default=DEFAULT_SCAN_OVERLAP_CHARS)
    parser.add_argument("--scan", action="append", default=[], metavar="NAME=REGEX")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        self_test()
        return 0
    if args.report is None:
        raise ValueError("--report is required unless --self-test is used")

    report = reduce_stream(
        sys.stdin.buffer,
        sys.stdout.buffer,
        maximum=args.max_bytes,
        patterns=parse_scan_patterns(args.scan),
        scan_overlap_chars=args.scan_overlap_chars,
    )
    write_report(args.report, report)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, re.error, ValueError) as error:
        print(f"bounded-log-scan: {error}", file=sys.stderr)
        raise SystemExit(2)
