#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPANION_DIR="$REPO_ROOT/CompanionApps/Android"
COMPANION_PORT="${COMPANION_PORT:-22088}"
DEVICE_SERIAL="${DEVICE_SERIAL:-}"
SKIP_BUILD=false
ADB_BASE=(adb)
INSTRUMENT_PID=""

log() {
    printf '[e2e-android] %s\n' "$*"
}

error() {
    printf '[e2e-android] ERROR: %s\n' "$*" >&2
}

usage() {
    cat <<EOF
Usage: scripts/run-e2e-android.sh [--skip-build] [--device <serial>] [--help]

Run the Android emulator companion e2e flow.

Options:
  --skip-build       Reuse the existing Android companion artifacts
  --device <serial>  Target a specific emulator/device serial
  --help             Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --device)
            DEVICE_SERIAL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument '$1'"
            usage >&2
            exit 1
            ;;
    esac
done

select_device() {
    if [[ -n "$DEVICE_SERIAL" ]]; then
        return
    fi

    DEVICE_SERIAL="$("${ADB_BASE[@]}" devices | awk 'NR>1 && $2 == "device" { print $1; exit }')"
    if [[ -z "$DEVICE_SERIAL" ]]; then
        error "No connected Android emulator/device found."
        exit 1
    fi
}

cleanup() {
    log "Cleaning up..."
    if [[ -n "$INSTRUMENT_PID" ]]; then
        kill "$INSTRUMENT_PID" 2>/dev/null || true
        wait "$INSTRUMENT_PID" 2>/dev/null || true
    fi
    "${ADB_BASE[@]}" -s "$DEVICE_SERIAL" shell am force-stop com.amoo.companion.test >/dev/null 2>&1 || true
    "${ADB_BASE[@]}" -s "$DEVICE_SERIAL" forward --remove "tcp:$COMPANION_PORT" >/dev/null 2>&1 || true
    log "Done."
}

trap cleanup EXIT

select_device
ADB_BASE=(adb -s "$DEVICE_SERIAL")
log "Selected device: $DEVICE_SERIAL"

log "Running Android preflight..."
(cd "$REPO_ROOT" && swift run amoo preflight --platform android)

if [[ "$SKIP_BUILD" == false ]]; then
    log "Installing Android companion via CLI..."
    (cd "$REPO_ROOT" && swift run amoo companion install --platform android --device "$DEVICE_SERIAL")
else
    log "Skipping build/install (--skip-build)."
fi

log "Forwarding localhost:$COMPANION_PORT to device port $COMPANION_PORT..."
"${ADB_BASE[@]}" forward "tcp:$COMPANION_PORT" "tcp:$COMPANION_PORT"

log "Starting Android companion instrumentation..."
"${ADB_BASE[@]}" shell am instrument \
    -w \
    -e class com.amoo.companion.CompanionRunner \
    com.amoo.companion.test/androidx.test.runner.AndroidJUnitRunner \
    2>&1 | sed 's/^/  [companion] /' &
INSTRUMENT_PID=$!

MAX_WAIT=30
WAITED=0
log "Waiting for companion gRPC server on port $COMPANION_PORT..."
while ! nc -z 127.0.0.1 "$COMPANION_PORT" 2>/dev/null; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        error "Companion did not start within ${MAX_WAIT}s."
        exit 1
    fi
done
log "Companion is reachable after ${WAITED}s."

log "Running integration tests..."
(cd "$REPO_ROOT" && COMPANION_PORT="$COMPANION_PORT" E2E_PLATFORM="android" E2E_DEVICE_ID="$DEVICE_SERIAL" E2E_APP_ID="com.amoo.companion" swift test --filter IntegrationTests)
