import contextlib
import io
import json
import pathlib
import subprocess
import types
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "plugins/amoo/skills/driving-amoo/scripts/check-install.py"
CHECK = types.ModuleType("check_agent_install")
exec(compile(SCRIPT.read_text(), str(SCRIPT), "exec"), CHECK.__dict__)


class AgentInstallCheckTests(unittest.TestCase):
    def run_check(self, report, returncode=0):
        output = report if isinstance(report, str) else json.dumps(report)
        result = subprocess.CompletedProcess([], returncode, output, "")
        with patch.object(CHECK.subprocess, "run", return_value=result) as run:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                status = CHECK.main(["--amoo", "/build/amoo", "--target", "/repo", "--client", "opencode"])
        self.assertEqual(run.call_args.args[0], [
            "/build/amoo", "agent", "install", "--target", "/repo", "--dry-run", "--json", "--client", "opencode"
        ])
        return status

    def test_current_install_passes(self):
        self.assertEqual(self.run_check({"ok": True, "files": [{"path": "skill", "action": "unchanged"}]}), 0)

    def test_stale_missing_and_unknown_actions_fail(self):
        for action in ["skipped (differs; use --force)", "would install", "would update", "unexpected"]:
            with self.subTest(action=action):
                self.assertEqual(self.run_check({"ok": True, "files": [{"path": "skill", "action": action}]}), 1)

    def test_invalid_or_failed_previews_fail(self):
        for report in ["not json", [], {"ok": False}, {"ok": True, "files": []}, {"ok": True, "files": [{}]}]:
            with self.subTest(report=report):
                self.assertEqual(self.run_check(report), 1)
        self.assertEqual(self.run_check({"ok": True, "files": [{"path": "skill", "action": "unchanged"}]}, 1), 1)
