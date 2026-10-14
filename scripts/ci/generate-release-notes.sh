#!/usr/bin/env bash
# Compatibility entry point; keep release-note logic and tests in one place.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/release-notes.py" "$@"
