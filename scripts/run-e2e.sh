#!/usr/bin/env bash
set -euo pipefail

# Backward-compatible iOS end-to-end entrypoint.
#
# Usage:
#   scripts/run-e2e.sh [--skip-build] [--device <udid|name>]
#
# Steps:
#   1. Build the companion app for the simulator
#   2. Install the companion into the booted simulator
#   3. Launch the companion XCUITest (starts gRPC server)
#   4. Wait for the companion to be reachable
#   5. Run the integration tests
#   6. Tear down

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPANION_DIR="$REPO_ROOT/CompanionApps/iOS"
COMPANION_PROJECT="$COMPANION_DIR/MobileTestingCompanion.xcodeproj"
DERIVED_DATA="$COMPANION_DIR/build"
COMPANION_PORT="${COMPANION_PORT:-22087}"
DEVICE="${DEVICE:-booted}"
SKIP_BUILD=false
XCTESTRUN_PID=""
SIMCTL_JSON=""
XCDEVICE_JSON=""

log() {
    printf '[e2e] %s\n' "$*"
}

warn() {
    printf '[e2e] WARNING: %s\n' "$*" >&2
}

error() {
    printf '[e2e] ERROR: %s\n' "$*" >&2
}

usage() {
    cat <<EOF
Usage: scripts/run-e2e.sh [--skip-build] [--device <udid|name>] [--help]

Run the repo-root iOS companion e2e flow against a simulator.

Options:
  --skip-build       Reuse the existing companion build products
  --device <value>   Use a specific simulator UDID or name
  --help             Show this help text

Default behavior:
  - Looks for a booted iOS simulator
  - If exactly one is booted, uses it
  - If multiple are booted, prompts you to choose when running interactively
  - If none are booted, fails early and tells you how to boot one

Examples:
  scripts/run-e2e.sh
  scripts/run-e2e.sh --skip-build
  scripts/run-e2e.sh --device "iPhone 17 Pro"
  scripts/run-e2e.sh --device 3BE7B404-5A28-48CD-B827-8CBCF4B2FF73
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --device)
            if [[ $# -lt 2 ]]; then
                echo "[e2e] ERROR: --device requires a simulator UDID or name." >&2
                usage >&2
                exit 1
            fi
            DEVICE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[e2e] ERROR: Unknown argument '$1'." >&2
            usage >&2
            exit 1
            ;;
    esac
done

load_device_catalogs() {
    if ! SIMCTL_JSON="$(xcrun simctl list devices -j 2>/dev/null)"; then
        error "Unable to query simulators via simctl. Make sure Xcode and CoreSimulator are available."
        exit 1
    fi

    if ! XCDEVICE_JSON="$(xcrun xcdevice list --timeout 2 2>/dev/null)"; then
        warn "Unable to query connected physical devices via xcdevice. Physical-device detection will be skipped."
        XCDEVICE_JSON="[]"
    fi
}

query_targets() {
    local mode="$1"
    local needle="${2:-}"

    SIMCTL_JSON="$SIMCTL_JSON" XCDEVICE_JSON="$XCDEVICE_JSON" python3 - "$mode" "$needle" <<'PY'
import json
import os
import sys


def pretty_runtime(runtime: str) -> str:
    suffix = runtime.rsplit(".", 1)[-1]
    if suffix.startswith("iOS-"):
        version = suffix[len("iOS-"):].replace("-", ".")
        return f"iOS {version}"
    return runtime


mode = sys.argv[1]
needle = sys.argv[2]
simctl = json.loads(os.environ.get("SIMCTL_JSON", "{}") or "{}")
xcdevice = json.loads(os.environ.get("XCDEVICE_JSON", "[]") or "[]")
rows = []

for runtime, devices in simctl.get("devices", {}).items():
    if "SimRuntime.iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        rows.append(
            {
                "kind": "simulator",
                "identifier": device["udid"],
                "name": device["name"],
                "os": pretty_runtime(runtime),
                "state": device.get("state", "Shutdown"),
                "available": "true",
                "detail": "simulator",
            }
        )

for device in xcdevice:
    if device.get("simulator"):
        continue
    if device.get("platform") != "com.apple.platform.iphoneos":
        continue
    error = device.get("error") or {}
    detail = device.get("interface", "unknown")
    if error.get("description"):
        detail = f"{detail}; {error['description']}"
    rows.append(
        {
            "kind": "physical",
            "identifier": device["identifier"],
            "name": device["name"],
            "os": device.get("operatingSystemVersion", "iOS"),
            "state": "Available" if device.get("available") else "Unavailable",
            "available": "true" if device.get("available") else "false",
            "detail": detail,
        }
    )


def emit(matches):
    for row in matches:
        print(
            "\t".join(
                [
                    row["kind"],
                    row["identifier"],
                    row["name"],
                    row["os"],
                    row["state"],
                    row["available"],
                    row["detail"],
                ]
            )
        )


if mode == "booted_simulators":
    matches = [row for row in rows if row["kind"] == "simulator" and row["state"] == "Booted"]
    matches.sort(key=lambda row: (row["name"], row["os"], row["identifier"]))
    emit(matches)
elif mode == "available_simulators":
    matches = [row for row in rows if row["kind"] == "simulator"]
    seen = set()
    unique = []
    for row in sorted(matches, key=lambda row: (row["name"], row["os"], row["identifier"])):
        key = (row["name"], row["os"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    emit(unique[:8])
elif mode == "physical_devices":
    matches = [row for row in rows if row["kind"] == "physical"]
    matches.sort(key=lambda row: (row["state"] != "Available", row["name"], row["identifier"]))
    emit(matches)
elif mode == "selector_matches":
    matches = [row for row in rows if row["identifier"] == needle or row["name"] == needle]
    matches.sort(
        key=lambda row: (
            row["kind"] != "simulator",
            row["state"] != "Booted",
            row["state"] != "Available",
            row["name"],
            row["os"],
            row["identifier"],
        )
    )
    emit(matches)
else:
    raise SystemExit(f"unsupported mode: {mode}")
PY
}

collect_targets() {
    local mode="$1"
    local needle="${2:-}"
    local line
    local results=()

    while IFS= read -r line; do
        results+=("$line")
    done < <(query_targets "$mode" "$needle")

    printf '%s\n' "${results[@]}"
}

describe_target() {
    local target="$1"
    local kind identifier name os state available detail
    IFS=$'\t' read -r kind identifier name os state available detail <<< "$target"
    if [[ "$kind" == "simulator" ]]; then
        printf '%s [%s] %s (%s)' "$name" "$os" "$state" "$identifier"
    else
        printf '%s [%s] %s via %s (%s)' "$name" "$os" "$state" "$detail" "$identifier"
    fi
}

print_target_list() {
    local header="$1"
    shift || true
    local target
    log "$header"
    for target in "$@"; do
        printf '  - %s\n' "$(describe_target "$target")" >&2
    done
}

choose_target() {
    local reason="$1"
    shift
    local options=("$@")
    local count="${#options[@]}"

    if [[ "$count" -eq 1 ]]; then
        printf '%s\n' "${options[0]}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        error "Multiple $reason were found. Re-run with --device <udid|name>."
        print_target_list "Matching targets:" "${options[@]}"
        exit 1
    fi

    printf '[e2e] Multiple %s were found. Choose one:\n' "$reason" >&2
    local index=1
    local option
    for option in "${options[@]}"; do
        printf '  %d) %s\n' "$index" "$(describe_target "$option")" >&2
        index=$((index + 1))
    done

    local selection
    while true; do
        read -r -p "[e2e] Choose a target [1-$count]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= count )); then
            printf '%s\n' "${options[$((selection - 1))]}"
            return 0
        fi
        error "Invalid selection '$selection'."
    done
}

print_boot_instructions() {
    local suggestions=()
    while IFS= read -r suggestion; do
        [[ -n "$suggestion" ]] && suggestions+=("$suggestion")
    done < <(collect_targets available_simulators)

    warn "No booted iOS simulator is available for this repo-root e2e flow."
    cat >&2 <<'EOF'
[e2e] To start one:
  open -a Simulator
  xcrun simctl list devices available
  xcrun simctl boot "<simulator-udid>"
  xcrun simctl bootstatus "<simulator-udid>"

[e2e] Then rerun:
  scripts/run-e2e.sh --skip-build
EOF

    if [[ "${#suggestions[@]}" -gt 0 ]]; then
        print_target_list "Available simulator choices:" "${suggestions[@]}"
    fi
}

fail_for_physical_targets() {
    local targets=("$@")
    if [[ "${#targets[@]}" -eq 0 ]]; then
        return 0
    fi

    warn "Connected physical iPhone/iPad devices were detected."
    print_target_list "Connected physical devices:" "${targets[@]}"
    cat >&2 <<EOF
[e2e] This repo-root e2e flow cannot use physical devices yet.
[e2e] Reason:
  - The integration tests connect to 127.0.0.1:$COMPANION_PORT
  - The iOS driver still relies on simctl for host-side actions

[e2e] Boot a simulator instead, or extend the test transport before using physical hardware.
EOF
    exit 1
}

resolve_target() {
    local matches=()
    local physical=()
    local selected
    local kind identifier name os state available detail

    if [[ "$DEVICE" == "booted" ]]; then
        while IFS= read -r match; do
            [[ -n "$match" ]] && matches+=("$match")
        done < <(collect_targets booted_simulators)
        if [[ "${#matches[@]}" -eq 0 ]]; then
            while IFS= read -r device; do
                [[ -n "$device" ]] && physical+=("$device")
            done < <(collect_targets physical_devices)
            if [[ "${#physical[@]}" -gt 0 ]]; then
                fail_for_physical_targets "${physical[@]}"
            fi
            print_boot_instructions
            exit 1
        fi
        selected="$(choose_target "booted simulators" "${matches[@]}")"
    else
        while IFS= read -r match; do
            [[ -n "$match" ]] && matches+=("$match")
        done < <(collect_targets selector_matches "$DEVICE")
        if [[ "${#matches[@]}" -eq 0 ]]; then
            error "No simulator or physical device matched '$DEVICE'."
            print_boot_instructions
            exit 1
        fi
        selected="$(choose_target "matching targets for '$DEVICE'" "${matches[@]}")"
    fi

    IFS=$'\t' read -r kind identifier name os state available detail <<< "$selected"
    if [[ "$kind" != "simulator" ]]; then
        fail_for_physical_targets "$selected"
    fi

    printf '%s\n' "$selected"
}

load_device_catalogs
TARGET="$(resolve_target)"
IFS=$'\t' read -r TARGET_KIND TARGET_ID TARGET_NAME TARGET_OS TARGET_STATE TARGET_AVAILABLE TARGET_DETAIL <<< "$TARGET"
DESTINATION="platform=iOS Simulator,id=$TARGET_ID"

log "Selected target: $(describe_target "$TARGET")"

cleanup() {
    log "Cleaning up..."
    if [[ -n "$XCTESTRUN_PID" ]]; then
        kill "$XCTESTRUN_PID" 2>/dev/null || true

        local waited=0
        while kill -0 "$XCTESTRUN_PID" 2>/dev/null; do
            if [[ $waited -ge 10 ]]; then
                warn "Companion process did not exit after 10s; forcing termination."
                kill -9 "$XCTESTRUN_PID" 2>/dev/null || true
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done

        wait "$XCTESTRUN_PID" 2>/dev/null || true
    fi
    log "Done."
}

trap cleanup EXIT

# Step 1: Build companion
if [[ "$SKIP_BUILD" == false ]]; then
    log "Building companion app..."
    cd "$COMPANION_DIR"
    xcodegen generate 2>&1 | sed 's/^/  /'
    xcodebuild build-for-testing \
        -project "$COMPANION_PROJECT" \
        -scheme MobileTestingCompanion \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        2>&1 | tail -5
    log "Build succeeded."
else
    log "Skipping build (--skip-build)."
fi

# Step 2: Find the xctestrun file
XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -name "*.xctestrun" -maxdepth 1 | head -1)
if [[ -z "$XCTESTRUN" ]]; then
    error "No .xctestrun file found. Build may have failed."
    exit 1
fi
log "Using xctestrun: $(basename "$XCTESTRUN")"

# Step 3: Launch companion XCUITest in background
log "Starting companion on port $COMPANION_PORT..."
xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "$DESTINATION" \
    -only-testing "MobileTestingCompanionUITests/CompanionRunner/testRunCompanion" \
    2>&1 | sed 's/^/  [companion] /' &
XCTESTRUN_PID=$!

# Step 4: Wait for companion to be reachable
log "Waiting for companion gRPC server on port $COMPANION_PORT..."
MAX_WAIT=30
WAITED=0
while ! nc -z 127.0.0.1 "$COMPANION_PORT" 2>/dev/null; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        error "Companion did not start within ${MAX_WAIT}s."
        exit 1
    fi
done
log "Companion is reachable after ${WAITED}s."

# Step 5: Run integration tests
log "Running integration tests..."
cd "$REPO_ROOT"
COMPANION_PORT="$COMPANION_PORT" E2E_PLATFORM="ios" E2E_DEVICE_ID="$TARGET_ID" E2E_APP_ID="com.mobiletesting.companion" swift test --filter IntegrationTests 2>&1
E2E_EXIT=$?

if [[ $E2E_EXIT -eq 0 ]]; then
    log "All integration tests passed."
else
    error "Integration tests failed with exit code $E2E_EXIT."
fi

exit $E2E_EXIT
