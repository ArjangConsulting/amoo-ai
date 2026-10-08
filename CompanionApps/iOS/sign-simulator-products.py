"""Ad hoc sign simulator apps, including the generated runner's public app-group entitlement."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile


def info(bundle):
    with (bundle / 'Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def simulator_bundles(root):
    bundles = set()
    for app in root.rglob('*.app'):
        if 'iPhoneSimulator' not in info(app).get('CFBundleSupportedPlatforms', []):
            continue
        bundles.add(app)
        bundles.update(p for p in app.rglob('*') if p.suffix in ('.framework', '.xctest', '.dylib'))
    return sorted(bundles, key=lambda p: len(p.parts), reverse=True)


def recovery_group(bundle):
    if bundle.suffix != '.app':
        return None
    contents = info(bundle)
    if contents.get('CFBundleIdentifier', '').endswith('.xctrunner'):
        test_info = next(bundle.glob('PlugIns/*.xctest/Info.plist'))
        with test_info.open('rb') as stream:
            contents = plistlib.load(stream)
    group = contents.get('AmooRecoveryAppGroup')
    if group and (not group.startswith('group.') or '$' in group):
        raise ValueError('Recovery app group must be a resolved group identifier')
    return group


def sign_products(root):
    bundles = simulator_bundles(root)
    runner_groups = {recovery_group(p) for p in bundles if p.name == 'AmooCompanionUITests-Runner.app'}
    runner_groups.discard(None)
    if len(runner_groups) > 1:
        raise ValueError('Simulator products contain inconsistent recovery group identifiers')
    shared_group = next(iter(runner_groups), None)
    for bundle in bundles:
        command = ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none']
        group = recovery_group(bundle)
        if bundle.name == 'AmooCompanion.app':
            group = shared_group
        if group:
            with tempfile.NamedTemporaryFile(suffix='.plist') as stream:
                stream.write(plistlib.dumps({'com.apple.security.application-groups': [group]}))
                stream.flush()
                subprocess.run(command + ['--entitlements', stream.name, str(bundle)], check=True)
        else:
            subprocess.run(command + [str(bundle)], check=True)


if __name__ == '__main__':
    sign_products(pathlib.Path(sys.argv[1]))
