#!/usr/bin/env bash
# Smoke test for `--platform macos`: drives Calculator on this Mac's desktop through the macOS
# companion. Calculator has no documents, so nothing is left behind on a developer machine.
#
# It checks the whole path a session depends on: the preflight, building and starting the companion,
# launching an app, identifying the foreground app, a screenshot, taps, and reading a value back.
#
# Usage:
#   scripts/run-e2e-macos.sh [--amoo <path>] [--enable-automation-mode] [--hide-dock]
#
#   --amoo <path>              amoo binary to test (default: AMOO_BIN, else .build/debug/amoo)
#   --enable-automation-mode   run `sudo -n automationmodetool enable-automationmode-without-authentication`
#                              first. For CI runners with passwordless sudo; a developer Mac is asked once
#                              by `amoo preflight --platform macos` instead.
#   --hide-dock                auto-hide the Dock for the run and restore it on exit. A small screen puts
#                              Calculator's bottom row under the Dock, where a tap opens a Dock app
#                              instead. CI passes this; the script fails early if a key is covered.
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
HIDE_DOCK=0
DOCK_RESTORE=""

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
    --hide-dock)
      HIDE_DOCK=1
      shift
      ;;
    -h | --help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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

# Prints "x y width height" (points, origin top-left) of the main screen's visible frame, which
# excludes the menu bar and a Dock that is not auto-hidden.
visible_frame() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); const s = $.NSScreen.screens.objectAtIndex(0); const f = s.frame; const v = s.visibleFrame; [v.origin.x, f.size.height - (v.origin.y + v.size.height), v.size.width, v.size.height].map(Math.round).join(" ")'
}

# Prints "centerX centerY width height" for the single element matching `id=<key>`.
element_frame() {
  local output
  output="$(device find_elements "id=$1")" || return 1
  sed -n 's/.*hitPoint: (\(-\{0,1\}[0-9][0-9]*\),\(-\{0,1\}[0-9][0-9]*\)) pts \([0-9][0-9]*\)x\([0-9][0-9]*\).*/\1 \2 \3 \4/p' <<<"$output" | head -n 1
}

# Fails unless every key lies inside the visible frame, so a covered key is reported as such
# rather than as a wrong result later.
assert_keys_reachable() {
  local vx vy vw vh key cx cy w h
  read -r vx vy vw vh <<<"$(visible_frame)" || fail "could not read the visible screen frame"
  [[ -n "${vw:-}" ]] || fail "could not read the visible screen frame"
  echo "Visible screen frame: x=$vx y=$vy ${vw}x${vh} pts"
  for key in "$@"; do
    read -r cx cy w h <<<"$(element_frame "$key")"
    [[ -n "${h:-}" ]] || fail "could not locate the $key key"
    echo "$key key: centre ($cx,$cy) ${w}x${h} pts"
    if ((cx - w / 2 < vx || cy - h / 2 < vy || cx + w / 2 > vx + vw || cy + h / 2 > vy + vh)); then
      fail "the $key key is outside the visible screen area (Dock or screen edge), so a tap would miss Calculator; rerun with --hide-dock or a larger display"
    fi
  done
}

# A tap that lands on the Dock or another window moves focus, so check Calculator kept it.
assert_calculator_frontmost() {
  local current
  current="$(device current_app)"
  [[ "$current" == *"frontmost=$APP_ID"* ]] || fail "after $1 the frontmost app was not $APP_ID (the tap hit something else): $current"
}

set_dock_autohide() {
  defaults write com.apple.dock autohide -bool "$1"
  killall Dock >/dev/null 2>&1 || true
}

# Waits until the visible frame stops changing, which is when the Dock has finished (un)hiding.
wait_for_dock_to_settle() {
  local previous="" current
  for _ in $(seq 1 20); do
    current="$(visible_frame)"
    [[ "$current" == "$previous" ]] && return 0
    previous="$current"
    sleep 1
  done
  fail "the Dock did not settle after changing auto-hide"
}

cleanup() {
  local status=$?
  set +e
  if [[ -n "$DOCK_RESTORE" ]]; then
    if [[ "$DOCK_RESTORE" == "missing" ]]; then
      defaults delete com.apple.dock autohide >/dev/null 2>&1
      killall Dock >/dev/null 2>&1
    else
      set_dock_autohide "$DOCK_RESTORE"
    fi
  fi
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

if [[ "$HIDE_DOCK" -eq 1 ]]; then
  step "Auto-hide the Dock"
  original_autohide="$(defaults read com.apple.dock autohide 2>/dev/null || echo missing)"
  case "$original_autohide" in
    1) DOCK_RESTORE="true" ;;
    0) DOCK_RESTORE="false" ;;
    *) DOCK_RESTORE="missing" ;;
  esac
  set_dock_autohide true
  wait_for_dock_to_settle
fi

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

step "Keys are reachable"
keys=(AllClear Seven Multiply Six Equals)
assert_keys_reachable "${keys[@]}"

step "Tap 7 x 6 ="
for key in "${keys[@]}"; do
  device tap_element "id=$key" >/dev/null || fail "tapping $key failed"
  assert_calculator_frontmost "tapping $key"
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
