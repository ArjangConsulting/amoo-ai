#!/usr/bin/env bash
# Start Claude Code with the amoo-live mod loaded from this checkout.
#
# Without --debug, the mirror runs the `amoo` on PATH (the Homebrew install). With --debug, it builds
# the checkout's `amoo` and points the mod's `amooPath` option at .build/debug/amoo through
# --settings, so unreleased commands such as `device stream` are used. User settings are not touched.
#
# Usage:
#   scripts/amoo-live.sh [claude args...]           # mirror uses the amoo on PATH
#   scripts/amoo-live.sh --debug [claude args...]   # mirror uses this checkout's debug build

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/plugins/amoo-live"
DEBUG=0

if [[ "${1:-}" == "--debug" ]]; then
  DEBUG=1
  shift
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,10p' "$0"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found." >&2
  exit 1
fi

if [[ "$DEBUG" == 1 ]]; then
  AMOO="$REPO/.build/debug/amoo"
  echo "Building ${AMOO}..." >&2
  (cd "$REPO" && swift build --product amoo)
  SETTINGS="{\"pluginConfigs\":{\"amoo-live\":{\"options\":{\"amooPath\":\"$AMOO\"}}}}"
  exec claude --plugin-dir "$PLUGIN" --settings "$SETTINGS" "$@"
fi

if ! command -v amoo >/dev/null 2>&1; then
  echo "amoo not found on PATH; install it (brew install arjangconsulting/tap/amoo) or use --debug." >&2
  exit 1
fi
exec claude --plugin-dir "$PLUGIN" "$@"
