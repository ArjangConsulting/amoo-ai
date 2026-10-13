#!/usr/bin/env python3
"""Run a companion command and bound teardown of its entire process group."""

import os
import signal
import subprocess
import sys
import time


def main():
    # Queue teardown signals until the child exists so an immediate cancellation
    # cannot leave an unsupervised Xcode process behind.
    signals = {signal.SIGTERM, signal.SIGINT}
    pending = []
    for signum in signals:
        signal.signal(signum, lambda received, _frame: pending.append(received))
    child = subprocess.Popen(sys.argv[1:], start_new_session=True)

    def stop(signum, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        try:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        finally:
            # Descendants can outlive the parent and keep CI output pipes open.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait()
        sys.exit(128 + signum)

    # Do not block in wait(): its internal lock can deadlock if a signal
    # handler tries to reap the same child while wait() holds that lock.
    while child.returncode is None:
        time.sleep(0.1)
        child.poll()
        if pending:
            stop(pending[0], None)
    status = child.returncode
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
