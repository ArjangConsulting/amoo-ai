import argparse
import json
import subprocess
import sys


def main(arguments=None):
    parser = argparse.ArgumentParser(description="Fail when installed Amoo agents or skills differ from the bundled templates.")
    parser.add_argument("--amoo", default="amoo", help="Pinned Amoo executable")
    parser.add_argument("--target", default=".", help="Repository containing the installed files")
    parser.add_argument("--client", action="append", required=True, help="Installed client; repeat for multiple clients")
    parser.add_argument("--binary", help="MCP executable pinned in the installed configuration")
    options = parser.parse_args(arguments)
    command = [options.amoo, "agent", "install", "--target", options.target, "--dry-run", "--json"]
    for client in options.client:
        command.extend(["--client", client])
    if options.binary:
        command.extend(["--binary", options.binary])
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            print(result.stderr or result.stdout or "Amoo install preview failed", file=sys.stderr)
            return 1
        report = json.loads(result.stdout)
        if not isinstance(report, dict) or report.get("ok") is not True:
            raise ValueError("install preview did not report ok=true")
        files = report.get("files")
        if not isinstance(files, list) or not files:
            raise ValueError("install preview did not report any files")
        drift = []
        for file in files:
            if not isinstance(file, dict) or not isinstance(file.get("path"), str) or not isinstance(file.get("action"), str):
                raise ValueError("install preview contains an invalid file entry")
            if file["action"] != "unchanged":
                drift.append(file)
        if drift:
            for file in drift:
                print(f'{file["action"]}: {file["path"]}', file=sys.stderr)
            print("Refresh with the same binary, target and clients using agent install --force.", file=sys.stderr)
            return 1
        print(f"Amoo installation is current ({len(files)} files).")
        return 0
    except (OSError, ValueError) as error:
        print(f"Cannot check Amoo installation: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
