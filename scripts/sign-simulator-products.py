"""Ad hoc sign release simulator executables without an Apple developer account."""
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
bundles = sorted(
    (p for p in root.rglob('*') if p.suffix in ('.app', '.framework', '.xctest', '.dylib')),
    key=lambda p: len(p.parts), reverse=True,
)
for bundle in bundles:
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
                    str(bundle)], check=True)
