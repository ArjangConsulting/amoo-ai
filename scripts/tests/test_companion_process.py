"""Verify companion teardown with real subprocesses, without a simulator."""

from pathlib import Path
import signal
import subprocess
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "run-companion-process.py"


class CompanionProcessTests(unittest.TestCase):
    def test_preserves_command_failure(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), sys.executable, "-c", "raise SystemExit(7)"],
            timeout=5,
        )
        self.assertEqual(result.returncode, 7)

    def test_cancellation_kills_descendants_holding_output_open(self):
        command = (
            "import subprocess, sys, time; "
            "subprocess.Popen([sys.executable, '-c', "
            "'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "print(\"ready\", flush=True); time.sleep(120)']); time.sleep(120)"
        )
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), sys.executable, "-c", command],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        self.assertEqual(process.stdout.readline().strip(), "ready")
        process.send_signal(signal.SIGTERM)
        # communicate also requires descendants to close their inherited pipes.
        process.communicate(timeout=15)
        self.assertEqual(process.returncode, 143)


if __name__ == "__main__":
    unittest.main()
