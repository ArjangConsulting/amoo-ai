#!/usr/bin/env python3
"""Exercise the exact packaged MCP executable without booting or driving a device."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


def request(identifier, method, params=None):
    result = {"jsonrpc": "2.0", "id": identifier, "method": method}
    if params is not None:
        result["params"] = params
    return result


INITIALIZE = request(0, "initialize", {
    "protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "amoo-release-smoke", "version": "1"},
})


def send(child, payload):
    child.stdin.write((json.dumps(payload) + "\n").encode())
    child.stdin.flush()


def receive(child, timeout=15):
    # Read one byte at a time to avoid buffering a second frame outside select's view.
    deadline = time.monotonic() + timeout
    result = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        while time.monotonic() < deadline:
            assert selector.select(max(0, deadline - time.monotonic())), "MCP response timed out"
            value = os.read(child.stdout.fileno(), 1)
            assert value, f"MCP closed before responding (exit={child.poll()})"
            if value == b"\n":
                return json.loads(result)
            result.extend(value)
    raise AssertionError("MCP response timed out")


def start(binary, directory, architecture=None):
    env = dict(os.environ, AMOO_SESSIONS_DIR=directory, AMOO_LEASE_DIR=directory,
               AMOO_CRASH_LOG=str(Path(directory) / "crash.log"))
    command = [binary, "mcp", "serve"]
    if architecture:
        command = ["/usr/bin/arch", "-" + architecture] + command
    return subprocess.Popen(command, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)


def finish(child):
    if child.poll() is None:
        child.kill()
    child.communicate(timeout=5)


def smoke(binary, fatal_signal=False, architecture=None):
    with tempfile.TemporaryDirectory(prefix="amoo-mcp-smoke-") as directory:
        child = start(binary, directory, architecture)
        try:
            send(child, INITIALIZE)
            initialized = receive(child)
            assert initialized["id"] == 0 and "result" in initialized, initialized
            assert initialized["result"]["_meta"]["dev.amoo/build"]["binary_sha256"]
            # Previously crashed the distributed release inside SingleCommandRunner.run().
            send(child, request(1, "tools/call", {"name": "list_devices", "arguments": {}}))
            discovered = receive(child, timeout=30)
            assert discovered["id"] == 1 and "result" in discovered, discovered
            # Numeric and string IDs must be preserved independently.
            send(child, request(2, "ping"))
            send(child, request("2", "ping"))
            responses = [receive(child), receive(child)]
            assert {type(value["id"]) for value in responses} == {int, str}, responses
            assert all("result" in value for value in responses), responses
            send(child, request(3, "tools/call", {
                "name": "get_session_report", "arguments": {"session_id": "does-not-exist"},
            }))
            failed_tool = receive(child)
            assert failed_tool["result"]["isError"], failed_tool
            send(child, request(4, "ping"))
            assert "result" in receive(child)
            child.stdin.close()
            child.stdin = None
            _, stderr = child.communicate(timeout=8)
            assert child.returncode == 0, stderr.decode(errors="replace")
        finally:
            finish(child)

        # Output disconnect must wake the input worker even when stdin remains open.
        child = start(binary, directory, architecture)
        try:
            child.stdout.close()
            send(child, INITIALIZE)
            child.wait(timeout=8)
            assert child.returncode == 1, child.returncode
        finally:
            finish(child)

        # SIGTERM should execute the same cleanup path as a disconnected client.
        child = start(binary, directory, architecture)
        try:
            send(child, INITIALIZE)
            receive(child)
            child.send_signal(signal.SIGTERM)
            child.wait(timeout=8)
            assert child.returncode == 0, child.returncode
        finally:
            finish(child)

        if fatal_signal:
            child = start(binary, directory, architecture)
            try:
                send(child, INITIALIZE)
                receive(child)
                child.send_signal(signal.SIGABRT)
                child.wait(timeout=8)
                assert child.returncode == -signal.SIGABRT, child.returncode
                assert "fatal signal" in (Path(directory) / "crash.log").read_text()
            finally:
                finish(child)
    print(f"MCP smoke passed: {binary}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--fatal-signal", action="store_true")
    parser.add_argument("--arch", choices=["arm64", "x86_64"])
    args = parser.parse_args()
    smoke(str(Path(args.binary).resolve()), args.fatal_signal, args.arch)
