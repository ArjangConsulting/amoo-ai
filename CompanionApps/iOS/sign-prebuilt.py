"""Sign a writable copy of release device products, without recompiling them.

Set AMOO_IOS_SIGNING_IDENTITY to a development certificate in the keychain,
AMOO_IOS_HOST_PROFILE to the com.amoo.companion provisioning profile, and
AMOO_IOS_RUNNER_PROFILE to the com.amoo.companion.uitests.xctrunner profile.
Both profiles must authorize the connected device and the signing identity.
VoiceOver recovery additionally requires a common app group in both profiles.
AMOO_IOS_RECOVERY_APP_GROUP may select a registered group instead of the build default.
"""
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

# Signed copies carry embedded provisioning profiles; stale ones are pruned on the next run.
MAX_COPY_AGE_SECONDS = 7 * 24 * 3600


def run(*argv):
    return subprocess.check_output(argv, stderr=subprocess.PIPE)


def profile(path):
    return plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', path))


def sign_app(app, identity, profile_path, device_id):
    contents = profile(profile_path)
    with (app / 'Info.plist').open('rb') as stream:
        bundle = plistlib.load(stream)['CFBundleIdentifier']
    if device_id not in contents.get('ProvisionedDevices', []):
        raise ValueError(f'Profile {profile_path} does not include device {device_id}')
    entitlements = contents['Entitlements'].copy()
    if not entitlements.get('get-task-allow'):
        raise ValueError(f'Profile {profile_path} must be a development profile')
    authorized = entitlements['application-identifier']
    team, suffix = authorized.split('.', 1)
    if suffix != bundle and not (suffix.endswith('*') and bundle.startswith(suffix[:-1])):
        raise ValueError(f'Profile {profile_path} does not authorize {bundle}')
    entitlements['application-identifier'] = f'{team}.{bundle}'
    entitlements['keychain-access-groups'] = [
        group.replace('*', bundle) for group in entitlements.get('keychain-access-groups', [])
    ]
    shutil.copy2(profile_path, app / 'embedded.mobileprovision')
    # Sign deepest nested executable bundles first; codesign --deep cannot apply profiles.
    nested = sorted(
        (p for p in app.rglob('*') if p.suffix in ('.framework', '.xctest', '.dylib')),
        key=lambda p: len(p.parts), reverse=True,
    )
    for binary in nested:
        run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', str(binary))
    with tempfile.NamedTemporaryFile(suffix='.plist') as stream:
        stream.write(plistlib.dumps(entitlements))
        stream.flush()
        run('/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none',
            '--entitlements', stream.name, str(app))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))


def prune_stale_copies(cache):
    cutoff = time.time() - MAX_COPY_AGE_SECONDS
    for old in cache.glob('device-*'):
        try:
            if old.is_dir() and old.stat().st_mtime < cutoff:
                shutil.rmtree(old, ignore_errors=True)
        except OSError:
            pass


def configure_recovery_group(runner, host_entitlements, runner_entitlements, requested_group=None):
    """Enable recovery only when both installed apps anchor the same authorized container."""
    info_path = next(runner.glob('PlugIns/*.xctest/Info.plist'))
    with info_path.open('rb') as stream:
        info = plistlib.load(stream)
    group = requested_group or info.get('AmooRecoveryAppGroup', 'group.com.amoo.companion')
    shared = set(host_entitlements.get('com.apple.security.application-groups', [])) & set(
        runner_entitlements.get('com.apple.security.application-groups', []))
    if requested_group and group not in shared:
        raise ValueError('AMOO_IOS_RECOVERY_APP_GROUP must be authorized by both host and runner profiles')
    # General commands remain usable without provisioning; VoiceOver capability is refused.
    info['AmooRecoveryAppGroup'] = group if group in shared else ''
    with info_path.open('wb') as stream:
        plistlib.dump(info, stream)


def main():
    identity = os.environ.get('AMOO_IOS_SIGNING_IDENTITY')
    host_profile = os.environ.get('AMOO_IOS_HOST_PROFILE')
    runner_profile = os.environ.get('AMOO_IOS_RUNNER_PROFILE')
    if not all((identity, host_profile, runner_profile)):
        raise ValueError('Set AMOO_IOS_SIGNING_IDENTITY, AMOO_IOS_HOST_PROFILE and '
                         'AMOO_IOS_RUNNER_PROFILE to sign the prebuilt device companion. '
                         'Profiles must include the device UDID.')
    source_run = pathlib.Path(sys.argv[1]).resolve()
    # Each invocation owns its copy, avoiding shared signing races and Cellar mutations.
    cache = pathlib.Path.home() / '.amoo' / 'signed-companions'
    cache.mkdir(parents=True, exist_ok=True)
    prune_stale_copies(cache)
    target = pathlib.Path(tempfile.mkdtemp(prefix='device-', dir=cache)) / 'Products'
    try:
        shutil.copytree(source_run.parent, target)
        apps = list(target.rglob('*.app'))
        host = next(p for p in apps if p.name == 'AmooCompanion.app')
        runner = next(p for p in apps if p.name == 'AmooCompanionUITests-Runner.app')
        configure_recovery_group(
            runner, profile(host_profile)['Entitlements'], profile(runner_profile)['Entitlements'],
            os.environ.get('AMOO_IOS_RECOVERY_APP_GROUP'))
        sign_app(host, identity, host_profile, sys.argv[2])
        sign_app(runner, identity, runner_profile, sys.argv[2])
        print(target / source_run.name)
    except Exception:
        shutil.rmtree(target.parent, ignore_errors=True)
        raise


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
