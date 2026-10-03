"""Verify every companion test-run descriptor resolves within relocated products."""
import pathlib
import plistlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
runs = list(root.glob('*.xctestrun'))
if not runs:
    raise SystemExit('Missing companion .xctestrun')


def resolve(value, host=None):
    value = value.replace('__TESTROOT__', str(root))
    if host:
        value = value.replace('__TESTHOST__', str(host))
    path = pathlib.Path(value).resolve()
    if not path.is_relative_to(root) or not path.exists():
        raise SystemExit(f'Missing or non-relocatable product: {value}')
    return path


def validate(value):
    if isinstance(value, dict):
        host = resolve(value['TestHostPath']) if 'TestHostPath' in value else None
        for key, item in value.items():
            if key in ('TestBundlePath', 'UITargetAppPath'):
                resolve(item, host)
            validate(item)
    elif isinstance(value, list):
        for item in value:
            validate(item)


for run in runs:
    with run.open('rb') as stream:
        validate(plistlib.load(stream))
