"""Exercise iOS host-build ordering and failures without Xcode or a simulator."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class IOSE2EScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/run-e2e.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / self.script.name, self.script)
        products = self.root / "CompanionApps/iOS/build/Build/Products"
        (products / "Debug-iphonesimulator/AmooCompanion.app").mkdir(parents=True)
        (products / "fixture.xctestrun").touch()
        self.events = self.root / "events.jsonl"
        binaries = self.root / "bin"
        binaries.mkdir()
        fake = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_EVENTS"], "a") as log:
    log.write(json.dumps({"tool": name, "args": args}) + "\\n")
if name == "xcrun" and args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"udid": "sim-test", "name": "iPhone Test", "state": "Booted",
         "isAvailable": True}]}}))
elif name == "xcrun" and args[0] == "xcdevice":
    print("[]")
elif name == "swift":
    sys.exit(int(os.environ.get("BUILD_EXIT" if args[0] == "build" else "TEST_EXIT", "0")))
'''
        for name in ("xcrun", "swift", "nc"):
            path = binaries / name
            path.write_text(fake)
            path.chmod(0o755)
        (self.root / "scripts/run-companion-process.py").write_text(
            "import time\ntime.sleep(60)\n"
        )
        self.env = dict(os.environ, PATH=f"{binaries}{os.pathsep}{os.environ['PATH']}",
                        TEST_EVENTS=str(self.events))

    def run_script(self, *arguments, build_exit=0, test_exit=0):
        result = subprocess.run(
            ["bash", str(self.script), "--skip-build", "--device", "sim-test", *arguments],
            env=dict(self.env, BUILD_EXIT=str(build_exit), TEST_EXIT=str(test_exit)),
            capture_output=True, text=True, timeout=20,
        )
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        return result, events

    def test_companion_skip_still_builds_host_before_install_and_runs_without_building(self):
        result, events = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build_index = next(i for i, e in enumerate(events)
                           if e["tool"] == "swift" and e["args"][0] == "build")
        install_index = next(i for i, e in enumerate(events)
                             if e["tool"] == "xcrun" and "install" in e["args"])
        self.assertLess(build_index, install_index)
        self.assertIn("--build-tests", events[build_index]["args"])
        test = next(e for e in events if e["tool"] == "swift" and e["args"][0] == "test")
        self.assertIn("--skip-build", test["args"])

    def test_prebuilt_mode_never_compiles_host_tests(self):
        result, events = self.run_script("--skip-test-build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(e["tool"] == "swift" and e["args"][0] == "build" for e in events))
        self.assertTrue(any(e["tool"] == "swift" and "--skip-build" in e["args"] for e in events))

    def test_host_build_failure_preserves_exit_and_never_installs_fixture(self):
        result, events = self.run_script(build_exit=8)
        self.assertEqual(result.returncode, 8, result.stdout + result.stderr)
        self.assertFalse(any("install" in e["args"] for e in events))
        self.assertFalse(any(e["tool"] == "swift" and e["args"][0] == "test" for e in events))

    def test_test_failure_preserves_exit_and_cleans_up(self):
        result, _ = self.run_script("--skip-test-build", test_exit=7)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn("Cleaning up...", result.stdout)
        self.assertIn("Done.", result.stdout)


if __name__ == "__main__":
    unittest.main()
