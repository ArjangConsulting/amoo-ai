"""Profile authorization checks require no signing credentials or connected device."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

signer_path = pathlib.Path(__file__).resolve().parents[2] / 'CompanionApps/iOS/sign-prebuilt.py'
spec = importlib.util.spec_from_file_location('sign_prebuilt', signer_path)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class RecoverySigningTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.runner = pathlib.Path(self.scratch.name)
        self.info = self.runner / 'PlugIns/Tests.xctest/Info.plist'
        self.info.parent.mkdir(parents=True)
        self.info.write_bytes(plistlib.dumps({'AmooRecoveryAppGroup': 'group.com.amoo.companion'}))

    def groups(self, *groups):
        return {'com.apple.security.application-groups': list(groups)}

    def configured(self):
        return plistlib.loads(self.info.read_bytes())['AmooRecoveryAppGroup']

    def test_group_authorized_by_both_profiles_remains_enabled(self):
        groups = self.groups('group.com.amoo.companion')
        signing.configure_recovery_group(self.runner, groups, groups)
        self.assertEqual(self.configured(), 'group.com.amoo.companion')

    def test_runner_only_group_cannot_claim_durable_recovery(self):
        signing.configure_recovery_group(self.runner, self.groups(), self.groups('group.com.amoo.companion'))
        self.assertEqual(self.configured(), '')

    def test_shared_override_selects_registered_group(self):
        groups = self.groups('group.example.recovery')
        signing.configure_recovery_group(self.runner, groups, groups, 'group.example.recovery')
        self.assertEqual(self.configured(), 'group.example.recovery')

    def test_unshared_explicit_override_fails_before_signing(self):
        with self.assertRaises(ValueError):
            signing.configure_recovery_group(self.runner, self.groups(), self.groups(), 'group.example.recovery')


if __name__ == '__main__':
    unittest.main()
