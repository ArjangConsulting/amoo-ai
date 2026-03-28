#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$REPO_ROOT/scripts/run-e2e-ios.sh" "$@"
"$REPO_ROOT/scripts/run-e2e-android.sh" "$@"
