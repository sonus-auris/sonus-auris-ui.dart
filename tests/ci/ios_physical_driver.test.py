#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DRIVER_PATH = ROOT / "scripts" / "device-lab" / "flutter-run-driver.py"
SPEC = importlib.util.spec_from_file_location("flutter_run_driver", DRIVER_PATH)
assert SPEC and SPEC.loader
DRIVER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = DRIVER
SPEC.loader.exec_module(DRIVER)


CHILD = r'''
import os
import signal
import sys
import time

mode = sys.argv[1]
if mode == "never-ready":
    print("building", flush=True)
    time.sleep(2)
elif mode == "premature-sigterm":
    print("Flutter run key commands", flush=True)
    os.kill(os.getpid(), signal.SIGTERM)
elif mode == "failure-marker":
    print("Flutter run key commands", flush=True)
    print("Lost connection to device", flush=True)
    sys.stdin.readline()
    print("terminal failure", flush=True)
elif mode == "huge":
    print("Flutter run key commands START", flush=True)
    for index in range(5000):
        print(f"event-{index:05d}-" + "x" * 80, flush=True)
    sys.stdin.readline()
    print("END-after-quit", flush=True)
elif mode == "ignore-quit":
    print("Flutter run key commands", flush=True)
    sys.stdin.readline()
    time.sleep(2)
elif mode == "secret":
    print("/Users/alex/work person@example.com Bearer synthetic-token-12345", flush=True)
    print("Flutter run key commands on Alex's iPhone", flush=True)
    sys.stdin.readline()
    print("terminal", flush=True)
else:
    print("Flutter run key commands", flush=True)
    sys.stdin.readline()
    print("terminal after q", flush=True)
'''


class PhysicalIosDriverTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="sonus-ios-driver-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.child = self.root / "child.py"
        self.child.write_text(textwrap.dedent(CHILD), encoding="utf-8")

    def run_mode(
        self,
        mode: str,
        *,
        timeout: float = 1.0,
        hold: float = 0.05,
        maximum: int = 4096,
        quit_timeout: float = 1.0,
    ):
        output = io.StringIO()
        log = self.root / f"{mode}.log"
        result = DRIVER.run_driver(
            [sys.executable, str(self.child), mode],
            log,
            timeout_seconds=timeout,
            hold_seconds=hold,
            max_log_bytes=maximum,
            quit_timeout_seconds=quit_timeout,
            output=output,
        )
        return result, log.read_text(encoding="utf-8"), output.getvalue()

    def test_normal_ready_hold_and_driver_quit_passes(self) -> None:
        result, log, _ = self.run_mode("normal")
        self.assertTrue(result.passed, result)
        self.assertIn("terminal after q", log)
        self.assertIn("hold_completed=true", log)
        self.assertIn("premature_exit=false", log)

    def test_signal_exit_after_ready_but_before_hold_fails(self) -> None:
        result, log, _ = self.run_mode("premature-sigterm", hold=0.5)
        self.assertFalse(result.passed)
        self.assertTrue(result.premature_exit)
        self.assertEqual(result.return_code, -15)
        self.assertIn("hold_completed=false", log)

    def test_failure_marker_fails_even_after_normal_quit(self) -> None:
        result, log, _ = self.run_mode("failure-marker")
        self.assertFalse(result.passed)
        self.assertTrue(result.failure_marker_seen)
        self.assertIn("failure_marker_seen=true", log)

    def test_missing_readiness_times_out(self) -> None:
        result, log, _ = self.run_mode("never-ready", timeout=0.15)
        self.assertFalse(result.passed)
        self.assertTrue(result.timed_out)
        self.assertIn("device_lab_timeout=true", log)

    def test_quit_timeout_fails_even_when_termination_returns_sigterm(self) -> None:
        result, log, _ = self.run_mode(
            "ignore-quit", hold=0.01, quit_timeout=0.05
        )
        self.assertFalse(result.passed)
        self.assertTrue(result.quit_timed_out)
        self.assertIn("device_lab_quit_timeout=true", log)
        self.assertIn("device_lab_quit_timed_out=true", log)

    def test_large_log_keeps_start_and_terminal_context_under_limit(self) -> None:
        result, log, _ = self.run_mode("huge", maximum=1024)
        self.assertTrue(result.passed, result)
        self.assertLessEqual(len(log.encode("utf-8")), 1024)
        self.assertIn("START", log)
        self.assertIn("END-after-quit", log)
        self.assertIn("sonus-flutter-run-log-truncated", log)

    def test_live_and_retained_output_are_sanitized(self) -> None:
        result, log, live = self.run_mode("secret")
        self.assertTrue(result.passed, result)
        for text in (log, live):
            self.assertNotIn("/Users/alex", text)
            self.assertNotIn("person@example.com", text)
            self.assertNotIn("synthetic-token-12345", text)
            self.assertNotIn("Alex's iPhone", text)
            self.assertIn("<redacted>", text)
            self.assertIn("<physical-iPhone>", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
