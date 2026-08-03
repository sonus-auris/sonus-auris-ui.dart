#!/usr/bin/env python3
"""Executable regressions for the physical-iPhone Flutter run controller."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTROLLER = ROOT / "scripts/device-lab/flutter-run-controller.py"
POLICY = ROOT / "scripts/device-lab/evidence-policy.py"
HARNESS = ROOT / "scripts/device-lab/ios-attached-smoke.sh"


def child(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
    path.chmod(0o755)


def run_case(
    root: Path,
    name: str,
    body: str,
    *,
    succeeds: bool,
    timeout: float = 3.0,
    hold: float = 0.15,
    quit_timeout: float = 0.5,
) -> str:
    executable = root / f"{name}.py"
    log = root / f"{name}.log"
    child(executable, body)
    result = subprocess.run(
        [
            sys.executable,
            str(CONTROLLER),
            "--policy",
            str(POLICY),
            "--log",
            str(log),
            "--timeout-seconds",
            str(timeout),
            "--hold-seconds",
            str(hold),
            "--quit-timeout-seconds",
            str(quit_timeout),
            "--",
            str(executable),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=8,
        check=False,
    )
    assert (result.returncode == 0) is succeeds, (
        name,
        result.returncode,
        result.stdout,
        log.read_text(encoding="utf-8") if log.exists() else "<missing log>",
    )
    return log.read_text(encoding="utf-8")


def main() -> None:
    subprocess.run(
        [sys.executable, "-m", "py_compile", str(CONTROLLER)], check=True
    )
    subprocess.run(["bash", "-n", str(HARNESS)], check=True)
    harness = HARNESS.read_text(encoding="utf-8")
    for marker in (
        "scripts/device-lab/flutter-run-controller.py",
        "--policy scripts/device-lab/evidence-policy.py",
        '--timeout-seconds "$RUN_TIMEOUT_SECONDS"',
        '--hold-seconds "$READY_HOLD_SECONDS"',
        '--quit-timeout-seconds "$QUIT_TIMEOUT_SECONDS"',
        "chunked_log_drain=true",
        "readiness_hold_completed=true",
        "shared_evidence_policy=true",
        "device_class=physical-iPhone",
        "emulator=false",
    ):
        assert marker in harness, marker
    for forbidden in (
        "subprocess.Popen(",
        "selectors.DefaultSelector",
        "flutter clean",
        "simctl erase",
        "uninstall",
        "pm clear",
    ):
        assert forbidden not in harness, forbidden
    with tempfile.TemporaryDirectory(prefix="sonus-flutter-controller-") as temp:
        root = Path(temp)

        ready = run_case(
            root,
            "ready-burst",
            "import sys\n"
            "sys.stdout.write('ordinary-before-ready\\n'"
            " + 'Flutter run key commands\\n'"
            " + 'A Dart VM Service on Alex iPhone\\n'"
            " + '/Users/synthetic-user/AppIcon60x60@2x.png\\n'"
            " + 'Authorization: Bearer SYNTHETIC_SECRET_12345\\n')\n"
            "sys.stdout.flush()\n"
            "for line in sys.stdin:\n"
            "    if line.strip() == 'q':\n"
            "        print('shutdown-complete', flush=True)\n"
            "        break\n",
            succeeds=True,
        )
        assert "ordinary-before-ready" in ready
        assert "Flutter run key commands" in ready
        assert "<physical-iPhone>" in ready
        assert "/Users/<redacted>/AppIcon60x60@2x.png" in ready
        assert "Bearer <redacted>" in ready
        assert "synthetic-user" not in ready
        assert "SYNTHETIC_SECRET_12345" not in ready
        assert "shutdown-complete" in ready

        run_case(
            root,
            "failure-second-line",
            "import sys, time\n"
            "sys.stdout.write('ordinary\\nFailed to build iOS app\\n')\n"
            "sys.stdout.flush()\n"
            "time.sleep(0.2)\n"
            "raise SystemExit(1)\n",
            succeeds=False,
        )
        run_case(
            root,
            "lost-after-ready",
            "import sys\n"
            "sys.stdout.write('Flutter run key commands\\nLost connection to device\\n')\n"
            "sys.stdout.flush()\n"
            "for line in sys.stdin:\n"
            "    if line.strip() == 'q':\n"
            "        break\n",
            succeeds=False,
        )
        run_case(
            root,
            "early-exit-after-ready",
            "print('Flutter run key commands', flush=True)\n",
            succeeds=False,
            hold=0.8,
        )
        run_case(
            root,
            "no-ready",
            "print('ordinary output only', flush=True)\n",
            succeeds=False,
        )
        timed_out = run_case(
            root,
            "run-timeout",
            "import time\nprint('still building', flush=True)\ntime.sleep(5)\n",
            succeeds=False,
            timeout=0.3,
        )
        assert "device_lab_timeout=true" in timed_out
        quit_timed_out = run_case(
            root,
            "quit-timeout",
            "import time\n"
            "print('Flutter run key commands', flush=True)\n"
            "time.sleep(5)\n",
            succeeds=False,
            quit_timeout=0.2,
        )
        assert "device_lab_quit_timeout=true" in quit_timed_out

    print(
        "Flutter run controller contract passed: burst drain + readiness hold + "
        "failure/lost/no-ready/run-timeout/quit-timeout + shared redaction"
    )


if __name__ == "__main__":
    main()
