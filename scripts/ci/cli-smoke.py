#!/usr/bin/env python3
"""Exercise the exact packaged amoo CLI without booting or driving a device.

Run on the binary a release ships (`--arch` runs one slice of a universal binary), so a crash that
only the release compiler produces fails CI instead of the first user call.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


# A release abort otherwise reports only its message; name the crashing frames in CI logs.
BACKTRACE = {"SWIFT_BACKTRACE": "enable=yes,interactive=no,color=no"}


def run(binary, args, directory, architecture=None, timeout=60):
    env = dict(os.environ, AMOO_SESSIONS_DIR=directory, AMOO_RUNTIME_DIR=directory, **BACKTRACE)
    command = [binary] + args
    if architecture:
        command = ["/usr/bin/arch", "-" + architecture] + command
    return subprocess.run(command, capture_output=True, text=True, env=env, timeout=timeout, cwd=directory)


def check(condition, message, result):
    if not condition:
        raise SystemExit(f"{message}\nstdout: {result.stdout[-2000:]}\nstderr: {result.stderr[-2000:]}")


def smoke(binary, architecture=None):
    with tempfile.TemporaryDirectory(prefix="amoo-cli-smoke-") as directory:
        version = run(binary, ["version"], directory, architecture)
        check(version.returncode == 0 and "commit:" in version.stdout, "`amoo version` failed", version)

        tools = run(binary, ["--tools"], directory, architecture)
        names = set(tools.stdout.strip().split(","))
        expected = {"tap_element", "find_elements", "assert_visible", "device_launch_app"}
        check(tools.returncode == 0 and expected <= names, "`amoo --tools` is missing core tools", tools)

        schema = run(binary, ["capabilities", "--tool", "tap_element"], directory, architecture)
        check(schema.returncode == 0, "`amoo capabilities --tool` failed", schema)
        properties = json.loads(schema.stdout)["arguments"]["properties"]
        check("expect_id" in properties and "check_hittable" in properties, "tap_element schema is incomplete", schema)

        removed = run(binary, ["mcp", "serve"], directory, architecture)
        check(removed.returncode == 64 and "no longer runs an MCP server" in removed.stdout,
              "`amoo mcp serve` should explain that the server is gone", removed)

        # A flow of flow-only steps runs the whole flow pipeline and writes report.json, no device needed.
        flow = Path(directory) / "smoke.amoo.json"
        flow.write_text(json.dumps({"platform": "android", "steps": [
            {"tool": "wait", "arguments": {"duration_ms": 10}},
        ]}))
        out = Path(directory) / "out"
        ran = run(binary, ["flow", str(flow), "--device", "emulator-0", "--port", "1", "--output-dir", str(out)],
                  directory, architecture)
        check(ran.returncode == 0, "a device-free flow failed", ran)
        report = json.loads((out / "report.json").read_text())
        check(report["passed"] == 1 and report["failed"] == 0, "report.json does not record the step", ran)
    print(f"CLI smoke passed: {binary}" + (f" ({architecture})" if architecture else ""))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--arch", choices=["arm64", "x86_64"])
    args = parser.parse_args()
    smoke(str(Path(args.binary).resolve()), args.arch)
