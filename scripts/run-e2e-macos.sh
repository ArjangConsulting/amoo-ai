#!/usr/bin/env bash
# Smoke test for `--platform macos`: drives Calculator on this Mac's desktop through the macOS
# companion. Calculator has no documents, so nothing is left behind on a developer machine.
#
# It checks the whole path a session depends on: the preflight, building and starting the companion,
# launching an app, identifying the foreground app, a screenshot, taps, and reading a value back.
#
# Usage:
#   scripts/run-e2e-macos.sh [--amoo <path>] [--enable-automation-mode]
#
#   --amoo <path>              amoo binary to test (default: AMOO_BIN, else .build/debug/amoo)
#   --enable-automation-mode   run `sudo -n automationmodetool enable-automationmode-without-authentication`
#                              first. For CI runners with passwordless sudo; a developer Mac is asked once
#                              by `amoo preflight --platform macos` instead.
#
# Environment:
#   AMOO_MACOS_SMOKE_DIR   keep the screenshot and companion log here (default: a temporary directory
#                          removed on exit, because a screenshot shows the whole desktop)
#   AMOO_MACOS_PORT        companion port (default: 22086)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AMOO="${AMOO_BIN:-$REPO_ROOT/.build/debug/amoo}"
APP_ID="com.apple.calculator"
PORT="${AMOO_MACOS_PORT:-22086}"
ENABLE_AUTOMATION_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amoo)
      AMOO="$2"
      shift 2
      ;;
    --enable-automation-mode)
      ENABLE_AUTOMATION_MODE=1
      shift
      ;;
    -h | --help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "${AMOO_MACOS_SMOKE_DIR:-}" ]]; then
  OUT="$AMOO_MACOS_SMOKE_DIR"
  mkdir -p "$OUT"
  KEEP_OUT=1
else
  OUT="$(mktemp -d)"
  KEEP_OUT=0
fi

COMPANION_PID=""

step() {
  echo "==> $*"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

device() {
  "$AMOO" device --platform macos --device mac --port "$PORT" "$@"
}

all_elements() {
  local offset=0 page next
  for _ in $(seq 1 20); do
    page="$(device find_elements "offset=$offset")"
    printf '%s\n' "$page"
    next="$(sed -n 's/^More results: offset=\([0-9][0-9]*\).*/\1/p' <<<"$page" | head -n 1)"
    [[ -n "$next" ]] || return 0
    offset="$next"
  done
}

cleanup() {
  local status=$?
  set +e
  if [[ -x "$AMOO" ]]; then
    device device_terminate_app "app_id=$APP_ID" >/dev/null 2>&1
  fi
  if [[ -n "$COMPANION_PID" ]]; then
    kill "$COMPANION_PID" >/dev/null 2>&1
  fi
  if [[ "$KEEP_OUT" -eq 0 ]]; then
    rm -rf "$OUT"
  fi
  exit "$status"
}
trap cleanup EXIT

[[ "$(uname -s)" == "Darwin" ]] || fail "the macOS smoke test needs a Mac"
[[ -x "$AMOO" ]] || fail "no amoo binary at $AMOO (build it, or pass --amoo)"

if [[ "$ENABLE_AUTOMATION_MODE" -eq 1 ]]; then
  step "Allow Automation Mode without a password prompt"
  sudo -n automationmodetool enable-automationmode-without-authentication
fi

step "Preflight"
"$AMOO" preflight --platform macos

step "Start the macOS companion"
start_output="$("$AMOO" companion start --platform macos --device mac --app "$APP_ID" --port "$PORT" --detach)"
echo "$start_output"
COMPANION_PID="$(sed -n 's/.*(pid \([0-9][0-9]*\)).*/\1/p' <<<"$start_output" | head -n 1)"
[[ -n "$COMPANION_PID" ]] || fail "the companion did not report a pid"
cp "$(sed -n 's/^Log: //p' <<<"$start_output" | head -n 1)" "$OUT/companion.log" 2>/dev/null || true

step "Launch Calculator"
launch_output="$(device device_launch_app "app_id=$APP_ID")"
echo "$launch_output"
[[ "$launch_output" == *"verified=true"* ]] || fail "Calculator did not launch as the verified foreground app"

step "Foreground app is Calculator"
current_output="$(device current_app)"
echo "$current_output"
[[ "$current_output" == *"frontmost=$APP_ID"* ]] || fail "expected $APP_ID in front, got: $current_output"

step "Screenshot"
shot_output="$(device take_screenshot "output=$OUT/macos.png" return_image=false scale=0.25)"
echo "$shot_output"
[[ "$shot_output" != *"capture_suspect"* ]] || fail "the screenshot was flagged as suspect"
[[ "$(wc -c <"$OUT/macos.png")" -gt 10000 ]] || fail "the screenshot is empty or too small"

step "Elements are readable"
elements_output="$(device find_elements id=Equals)"
echo "$elements_output"
[[ "$elements_output" == *"Found 1 element"* ]] || fail "the Equals key was not found"

step "Tap 7 x 6 ="
for key in AllClear Seven Multiply Six Equals; do
  device tap_element "id=$key" >/dev/null || fail "tapping $key failed"
done

step "Read the result back"
result_seen=0
for _ in 1 2 3 4 5 6; do
  screen_elements="$(all_elements)"
  if [[ "$screen_elements" == *'value="42"'* || "$screen_elements" == *'value="forty two"'* ]]; then
    result_seen=1
    break
  fi
  sleep 1
done
if [[ "$result_seen" -ne 1 ]]; then
  printf '%s\n' "$screen_elements" >"$OUT/elements-final.txt"
  device take_screenshot "output=$OUT/macos-final.png" return_image=false scale=0.25 >/dev/null 2>&1 || true
  echo "Elements with a value:" >&2
  grep 'value=' <<<"$screen_elements" | head -n 20 >&2 || true
  fail "7 x 6 did not show 42"
fi

device tap_element id=AllClear >/dev/null || true

step "macOS smoke passed"
