"""Simulator signing must authorize the executable runner and leave device artifacts alone."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

signer_path = pathlib.Path(__file__).resolve().parents[2] / 'CompanionApps/iOS/sign-simulator-products.py'
spec = importlib.util.spec_from_file_location('simulator_signing', signer_path)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SimulatorSigningTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = pathlib.Path(self.scratch.name)

    def app(self, name, platform, bundle_id):
        app = self.root / name
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleSupportedPlatforms': [platform], 'CFBundleIdentifier': bundle_id,
        }))
        return app

    def test_group_reaches_host_and_generated_runner_not_only_test_bundle(self):
        host = self.app('AmooCompanion.app', 'iPhoneSimulator', 'com.amoo.companion')
        runner = self.app('AmooCompanionUITests-Runner.app', 'iPhoneSimulator', 'com.amoo.companion.uitests.xctrunner')
        test = runner / 'PlugIns/Tests.xctest'
        test.mkdir(parents=True)
        (test / 'Info.plist').write_bytes(plistlib.dumps({'AmooRecoveryAppGroup': 'group.example.recovery'}))
        captured = {}

        def capture(command, check):
            self.assertTrue(check)
            if '--entitlements' in command:
                entitlement = pathlib.Path(command[command.index('--entitlements') + 1])
                captured[pathlib.Path(command[-1])] = plistlib.loads(entitlement.read_bytes())

        with patch.object(signing.subprocess, 'run', side_effect=capture):
            signing.sign_products(self.root)
        self.assertEqual(set(captured), {host, runner})
        for entitlement in captured.values():
            self.assertEqual(entitlement['com.apple.security.application-groups'], ['group.example.recovery'])

    def test_device_products_are_never_ad_hoc_signed(self):
        self.app('Device.app', 'iPhoneOS', 'com.amoo.companion')
        with patch.object(signing.subprocess, 'run') as run:
            signing.sign_products(self.root)
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
