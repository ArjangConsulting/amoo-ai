#!/usr/bin/env python3
"""Exercise immediate init choices in a PTY. Run after swift build."""
import os
import pty
import select
import subprocess
import termios
import time
import unittest


class PromptTests(unittest.TestCase):
    def test_immediate_choices_and_retry(self):
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        process = subprocess.Popen(
            [".build/debug/amoo", "init"],
            stdin=slave, stdout=slave, stderr=slave,
            env={**os.environ, "NO_COLOR": "1", "TERM": "xterm-256color"},
        )
        pending = b""

        def expect(text):
            nonlocal pending
            deadline = time.monotonic() + 20
            while text not in pending:
                self.assertLess(time.monotonic(), deadline, repr(pending))
                if select.select([master], [], [], 0.1)[0]:
                    pending += os.read(master, 65536)
            pending = pending.split(text, 1)[1]

        try:
            expect(b"Enter select")
            os.write(master, b"\r")
            expect(b"App framework")
            expect(b"Enter select")
            os.write(master, b"\x1b[B")
            expect(b"> (*)")
            os.write(master, b"\x04")
            process.wait(timeout=10)
            restored = termios.tcgetattr(slave)
            # macOS sets PENDIN when terminal input settings change.
            ignored = getattr(termios, "PENDIN", 0)
            original[3] &= ~ignored
            restored[3] &= ~ignored
            self.assertEqual(original, restored)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    unittest.main()
