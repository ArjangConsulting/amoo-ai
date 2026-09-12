"""Exercise Android orchestration without requiring a device, Gradle, or Swift."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidE2EScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/run-e2e-android.sh"
        shutil.copyfile(Path(__file__).resolve().parents[1] / self.script.name, self.script)
        self.apk = self.root / (
            "CompanionApps/Android/composeSampleApp/build/outputs/apk/debug/composeSampleApp-debug.apk"
        )
        self.events = self.root / "events.jsonl"
        binaries = self.root / "bin"
        binaries.mkdir()
        fake = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TEST_EVENTS"], "a") as log:
    log.write(json.dumps({"tool": name, "args": args,
        "app": os.environ.get("E2E_APP_ID"),
        "device": os.environ.get("E2E_DEVICE_ID")}) + "\\n")
if name == "make":
    apk = pathlib.Path(os.environ["TEST_APK"])
    apk.parent.mkdir(parents=True, exist_ok=True)
    apk.touch()
if name == "swift" and args[0] == "test":
    sys.exit(int(os.environ.get("TEST_EXIT", "0")))
'''
        for name in ("adb", "swift", "make", "nc"):
            path = binaries / name
            path.write_text(fake)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{binaries}{os.pathsep}{os.environ['PATH']}",
                        TEST_EVENTS=str(self.events), TEST_APK=str(self.apk))

    def run_script(self, *arguments, test_exit=0):
        result = subprocess.run(
            ["bash", str(self.script), "--device", "emulator-test", *arguments],
            env=dict(self.env, TEST_EXIT=str(test_exit)),
            capture_output=True, text=True, timeout=20,
        )
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        return result, events

    def test_normal_run_builds_and_installs_separate_fixture(self):
        result, events = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        build_index = next(i for i, e in enumerate(events) if e["tool"] == "make")
        install_index = next(i for i, e in enumerate(events)
                             if e["tool"] == "adb" and "install" in e["args"])
        self.assertLess(build_index, install_index)
        self.assertIn("sample-app-compose-build", events[build_index]["args"])
        test = next(e for e in events if e["tool"] == "swift" and e["args"][0] == "test")
        self.assertEqual(test["app"], "com.amoo.samples.compose")
        self.assertEqual(test["device"], "emulator-test")

    def test_skip_build_reuses_fixture_but_still_installs_it(self):
        self.apk.parent.mkdir(parents=True)
        self.apk.touch()
        result, events = self.run_script("--skip-build")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(e["tool"] == "make" for e in events))
        self.assertTrue(any(e["tool"] == "adb" and "install" in e["args"] for e in events))

    def test_missing_fixture_fails_before_starting_instrumentation(self):
        result, events = self.run_script("--skip-build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Fixture APK not found", result.stderr)
        self.assertFalse(any("instrument" in e["args"] for e in events))

    def test_test_failure_is_preserved_and_cleanup_captures_logs(self):
        result, events = self.run_script(test_exit=7)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        adb_calls = [e["args"] for e in events if e["tool"] == "adb"]
        self.assertTrue(any("force-stop" in a and "com.amoo.companion" in a for a in adb_calls))
        self.assertTrue(any("--remove" in a for a in adb_calls))
        self.assertIn(["-s", "emulator-test", "logcat", "-d"], adb_calls)
        self.assertTrue((self.root / "logcat-android.log").exists())


if __name__ == "__main__":
    unittest.main()
