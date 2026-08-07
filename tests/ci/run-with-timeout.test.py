#!/usr/bin/env python3
"""Black-box contracts for the streaming command timeout helper."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/device-lab/run-with-timeout.py"


def invoke(arguments: list[str], *, timeout: float = 10) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [sys.executable, str(HELPER), *arguments],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def main() -> None:
    subprocess.run([sys.executable, "-m", "py_compile", str(HELPER)], check=True)
    subprocess.run([sys.executable, str(HELPER), "--self-test"], check=True)

    success = invoke(
        [
            "--timeout-seconds",
            "5",
            "--stderr",
            "merge",
            "--",
            sys.executable,
            "-u",
            "-c",
            "import sys; print('stdout'); print('stderr', file=sys.stderr)",
        ]
    )
    assert success.returncode == 0, success.stderr.decode(errors="replace")
    assert b"stdout\n" in success.stdout
    assert b"stderr\n" in success.stdout

    nonzero = invoke(
        [
            "--timeout-seconds",
            "5",
            "--stderr",
            "discard",
            "--",
            sys.executable,
            "-u",
            "-c",
            "print('retained-before-exit'); raise SystemExit(17)",
        ]
    )
    assert nonzero.returncode == 17
    assert nonzero.stdout == b"retained-before-exit\n"

    started = time.monotonic()
    timed = invoke(
        [
            "--timeout-seconds",
            "0.5",
            "--grace-seconds",
            "0.2",
            "--stderr",
            "discard",
            "--",
            sys.executable,
            "-u",
            "-c",
            "import time; print('retained-before-timeout', flush=True); time.sleep(30)",
        ]
    )
    elapsed = time.monotonic() - started
    assert timed.returncode == 124, timed.stderr.decode(errors="replace")
    assert b"retained-before-timeout\n" in timed.stdout
    assert b"command exceeded 0.5s" in timed.stderr
    assert elapsed < 4, elapsed

    missing = invoke(["--timeout-seconds", "1"])
    assert missing.returncode == 2
    assert b"a command is required" in missing.stderr

    # On Linux, verify timeout signals the whole process group rather than only
    # the direct child. A surviving grandchild would leak beyond a CI step.
    if sys.platform.startswith("linux"):
        with tempfile.TemporaryDirectory(prefix="sonus-command-timeout-") as temp:
            pid_file = Path(temp) / "grandchild.pid"
            program = (
                "import pathlib, subprocess, sys, time; "
                "child=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid)); "
                "print('tree-ready', flush=True); time.sleep(30)"
            )
            tree = invoke(
                [
                    "--timeout-seconds",
                    "0.8",
                    "--grace-seconds",
                    "0.2",
                    "--stderr",
                    "discard",
                    "--",
                    sys.executable,
                    "-u",
                    "-c",
                    program,
                ]
            )
            assert tree.returncode == 124
            assert b"tree-ready\n" in tree.stdout
            grandchild = int(pid_file.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                stat = Path(f"/proc/{grandchild}/stat")
                if not stat.exists():
                    break
                fields = stat.read_text(encoding="utf-8", errors="replace").split()
                if len(fields) > 2 and fields[2] == "Z":
                    break
                time.sleep(0.05)
            else:
                try:
                    os.kill(grandchild, 9)
                except ProcessLookupError:
                    pass
                raise AssertionError(
                    f"grandchild {grandchild} survived the timeout process-group cleanup"
                )

    print(
        "Command timeout contract passed: output drain + status propagation + "
        "deadline + missing-command refusal + process-group cleanup"
    )


if __name__ == "__main__":
    main()
