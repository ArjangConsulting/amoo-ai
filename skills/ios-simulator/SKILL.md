---
name: ios-simulator
description: Comprehensive guide for iOS Simulator management via xcrun simctl — device lifecycle, app management, screenshots, video recording, location simulation, push notifications, and accessibility testing.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-05 |
| Xcode Version | 16.x (Xcode command line tools) |
| macOS | 15.x+ / 26.x |
| simctl source | `xcrun simctl help` (authoritative) |

### Update checklist
- [ ] Run `xcrun simctl help` and diff against documented subcommands
- [ ] Check [Xcode Release Notes](https://developer.apple.com/documentation/xcode-release-notes) for new simulator features
- [ ] Check for new `simctl` subcommands or changed flags after Xcode updates

# iOS Simulator Skill

Expert-level reference for automating iOS Simulator interactions using `xcrun simctl` and related tooling.

## When to use

Use this skill when working with iOS Simulators for:
- Creating, booting, managing simulator devices
- Installing, launching, and inspecting apps
- Capturing screenshots and recording video
- Simulating location, push notifications, permissions
- Configuring device appearance and status bar
- Automating UI testing workflows

## Project Alignment (mobile-testing repo)

In this repository:

- Treat simulator lifecycle/app/config tasks as host-side responsibilities (`simctl`/`devicectl` wrappers).
- Treat UI interactions and hierarchy queries as companion-side responsibilities.
- Prefer deterministic preflight checks and actionable remediation messages when simulator state is invalid.

## Device Lifecycle

### List available resources

```bash
# List all available runtimes
xcrun simctl list runtimes available

# List all available device types
xcrun simctl list devicetypes

# List all devices (shows state: Booted/Shutdown)
xcrun simctl list devices available

# JSON output for programmatic parsing
xcrun simctl list devices available -j
```

### Create, boot, shutdown, delete

```bash
# Create a device (uses newest compatible runtime if omitted)
xcrun simctl create "TestDevice" "iPhone 16 Pro"
xcrun simctl create "TestDevice" "iPhone 16 Pro" "com.apple.CoreSimulator.SimRuntime.iOS-18-0"

# Boot a device (by UDID or name)
xcrun simctl boot <device-udid>

# Boot with specific architecture
xcrun simctl boot <device> --arch=arm64

# Shutdown
xcrun simctl shutdown <device>
xcrun simctl shutdown all  # shutdown all booted devices

# Delete
xcrun simctl delete <device>
xcrun simctl delete unavailable  # clean up old devices

# Erase (factory reset — wipes all data)
xcrun simctl erase <device>

# Clone an existing device
xcrun simctl clone <device> "ClonedDevice"

# Open Simulator.app (required to see GUI)
open -a Simulator
```

**Tip:** Use `"booted"` as the device argument to target the currently booted simulator. If multiple are booted, simctl picks one — prefer using UDIDs for determinism.

### Environment variables

Set environment variables for booted simulator processes by prefixing with `SIMCTL_CHILD_`:

```bash
export SIMCTL_CHILD_MY_ENV_VAR="value"
xcrun simctl boot <device>  # or launch
```

## App Management

### Install, launch, terminate, uninstall

```bash
# Install an app (.app bundle path)
xcrun simctl install <device> /path/to/MyApp.app

# Launch by bundle ID
xcrun simctl launch <device> com.example.myapp

# Launch with arguments
xcrun simctl launch <device> com.example.myapp --arg1 value1

# Launch and stream stdout/stderr to terminal
xcrun simctl launch --console <device> com.example.myapp

# Launch and redirect output to files
xcrun simctl launch --stdout=/tmp/out.log --stderr=/tmp/err.log <device> com.example.myapp

# Terminate a running app
xcrun simctl terminate <device> com.example.myapp

# Terminate and relaunch
xcrun simctl launch --terminate-running-process <device> com.example.myapp

# Uninstall
xcrun simctl uninstall <device> com.example.myapp
```

### Inspect installed apps

```bash
# Show info about an installed app
xcrun simctl appinfo <device> com.example.myapp

# List all installed apps (JSON output)
xcrun simctl listapps <device>

# Get app container paths
xcrun simctl get_app_container <device> com.example.myapp app     # .app bundle
xcrun simctl get_app_container <device> com.example.myapp data    # data container
xcrun simctl get_app_container <device> com.example.myapp groups  # app group containers
```

### Open URLs and add media

```bash
# Open a URL (deep links, universal links)
xcrun simctl openurl <device> "myapp://path/to/content"
xcrun simctl openurl <device> "https://example.com"

# Add photos/videos/contacts to device library
xcrun simctl addmedia <device> /path/to/photo.jpg /path/to/video.mp4
```

## Screenshots & Video Recording

### Screenshots

```bash
# PNG screenshot (default)
xcrun simctl io <device> screenshot screenshot.png

# Specify format
xcrun simctl io <device> screenshot --type=jpeg screenshot.jpg
# Supported types: png, tiff, bmp, gif, jpeg

# Screenshot to stdout (pipe to other tools)
xcrun simctl io <device> screenshot --type=png -

# Specific display (for multi-display devices)
xcrun simctl io <device> screenshot --display=internal screenshot.png
```

### Video recording

```bash
# Record video (HEVC by default, Control+C to stop)
xcrun simctl io <device> recordVideo output.mov

# H.264 codec (more compatible)
xcrun simctl io <device> recordVideo --codec=h264 output.mov

# Force overwrite existing file
xcrun simctl io <device> recordVideo --force output.mov

# Non-rectangular display mask options: ignored, alpha, black
xcrun simctl io <device> recordVideo --mask=black output.mov
```

**Important:** simctl writes `Recording started` to stderr once the first frame is processed. Use this to synchronize with test execution. Send SIGINT (Ctrl+C) to stop — simctl finalizes the file before exiting.

### Programmatic recording pattern

```bash
# Start recording in background
xcrun simctl io booted recordVideo --codec=h264 test_recording.mov &
RECORD_PID=$!

# Wait for recording to start
sleep 1

# ... run your tests ...

# Stop recording gracefully
kill -INT $RECORD_PID
wait $RECORD_PID
```

## Location Simulation

```bash
# Set a fixed location (lat,lon)
xcrun simctl location <device> set 37.7749,-122.4194  # San Francisco

# Clear simulated location
xcrun simctl location <device> clear

# List available movement scenarios
xcrun simctl location <device> list

# Run a built-in scenario
xcrun simctl location <device> run <scenario-name>

# Simulate movement along waypoints (20 m/s default speed)
xcrun simctl location <device> start 37.7749,-122.4194 37.3382,-121.8863

# Custom speed and update interval
xcrun simctl location <device> start --speed=30 --distance=100 37.7749,-122.4194 37.3382,-121.8863

# Read waypoints from stdin
echo "37.7749,-122.4194
37.3382,-121.8863" | xcrun simctl location <device> start -
```

## Push Notifications

```bash
# Send push notification from JSON file
xcrun simctl push <device> com.example.myapp notification.json

# Send from stdin
echo '{"aps":{"alert":"Hello","badge":1,"sound":"default"}}' | xcrun simctl push <device> com.example.myapp -

# If JSON contains "Simulator Target Bundle" key, bundle ID is optional
xcrun simctl push <device> notification_with_target.json
```

**Note:** Only application remote push notifications are supported. VoIP, Complication, and File Provider types are not supported.

### Example payload (notification.json)

```json
{
  "Simulator Target Bundle": "com.example.myapp",
  "aps": {
    "alert": {
      "title": "Test Notification",
      "body": "This is a simulated push notification"
    },
    "badge": 1,
    "sound": "default"
  }
}
```

## Privacy & Permissions

```bash
# Grant permissions without prompting
xcrun simctl privacy <device> grant photos com.example.myapp
xcrun simctl privacy <device> grant camera com.example.myapp
xcrun simctl privacy <device> grant location com.example.myapp
xcrun simctl privacy <device> grant location-always com.example.myapp
xcrun simctl privacy <device> grant microphone com.example.myapp
xcrun simctl privacy <device> grant contacts com.example.myapp
xcrun simctl privacy <device> grant calendar com.example.myapp
xcrun simctl privacy <device> grant reminders com.example.myapp
xcrun simctl privacy <device> grant motion com.example.myapp
xcrun simctl privacy <device> grant media-library com.example.myapp

# Revoke a permission
xcrun simctl privacy <device> revoke photos com.example.myapp

# Reset (will re-prompt on next use)
xcrun simctl privacy <device> reset all com.example.myapp
xcrun simctl privacy <device> reset all  # reset for all apps
```

**Warning:** Some permission changes terminate the running app.

## UI Configuration

### Appearance

```bash
# Get current appearance
xcrun simctl ui <device> appearance

# Set dark/light mode
xcrun simctl ui <device> appearance dark
xcrun simctl ui <device> appearance light
```

### Content size (Dynamic Type)

```bash
# Get current content size
xcrun simctl ui <device> content_size

# Set content size
xcrun simctl ui <device> content_size extra-large
xcrun simctl ui <device> content_size accessibility-large

# Increment/decrement
xcrun simctl ui <device> content_size increment
xcrun simctl ui <device> content_size decrement

# Sizes: extra-small, small, medium, large, extra-large,
#         extra-extra-large, extra-extra-extra-large,
#         accessibility-medium, accessibility-large,
#         accessibility-extra-large, accessibility-extra-extra-large,
#         accessibility-extra-extra-extra-large
```

### Increase Contrast

```bash
xcrun simctl ui <device> increase_contrast enabled
xcrun simctl ui <device> increase_contrast disabled
```

## Status Bar Overrides

Useful for consistent screenshots in CI/docs:

```bash
# Set common overrides for clean screenshots
xcrun simctl status_bar <device> override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4 \
  --dataNetwork wifi \
  --operatorName "Carrier"

# Clear all overrides
xcrun simctl status_bar <device> clear

# List current overrides
xcrun simctl status_bar <device> list

# Data network types: hide, wifi, 3g, 4g, lte, lte-a, lte+, 5g, 5g+, 5g-uwb, 5g-uc
```

## Keychain

```bash
# Add a root certificate (for proxy/MITM testing)
xcrun simctl keychain <device> add-root-cert /path/to/cert.pem

# Add a certificate to keychain
xcrun simctl keychain <device> add-cert /path/to/cert.pem

# Reset keychain
xcrun simctl keychain <device> reset
```

## Pasteboard

```bash
# Copy text to device pasteboard
echo "Hello" | xcrun simctl pbcopy <device>

# Paste from device pasteboard
xcrun simctl pbpaste <device>

# Sync pasteboard between devices
xcrun simctl pbsync <source-device> <dest-device>
```

## Process Spawning

```bash
# Spawn a process on the device
xcrun simctl spawn <device> /usr/bin/log stream --predicate 'subsystem == "com.example.myapp"'

# Spawn with specific architecture
xcrun simctl spawn --arch=arm64 <device> /path/to/binary

# Useful for streaming device logs during test execution
xcrun simctl spawn <device> log stream --level debug --predicate 'subsystem == "com.example.myapp"' &
```

## Diagnostics & Logging

```bash
# Collect diagnostic information
xcrun simctl diagnose

# Enable verbose logging for a device
xcrun simctl logverbose <device> enable

# Disable verbose logging
xcrun simctl logverbose <device> disable

# Stream logs from a device (via spawn)
xcrun simctl spawn <device> log stream --level info
xcrun simctl spawn <device> log stream --predicate 'processImagePath contains "MyApp"'
```

## Automation Patterns

### Full test workflow example

```bash
#!/bin/bash
set -euo pipefail

DEVICE_NAME="TestDevice"
BUNDLE_ID="com.example.myapp"
APP_PATH="./build/MyApp.app"

# 1. Create and boot
DEVICE_UDID=$(xcrun simctl create "$DEVICE_NAME" "iPhone 16 Pro")
xcrun simctl boot "$DEVICE_UDID"

# 2. Wait for boot to complete
xcrun simctl spawn "$DEVICE_UDID" launchctl print system | grep -q "com.apple.springboard.services" || sleep 5

# 3. Configure device
xcrun simctl ui "$DEVICE_UDID" appearance light
xcrun simctl status_bar "$DEVICE_UDID" override --time "9:41" --batteryState charged --batteryLevel 100

# 4. Install and grant permissions
xcrun simctl install "$DEVICE_UDID" "$APP_PATH"
xcrun simctl privacy "$DEVICE_UDID" grant all "$BUNDLE_ID"

# 5. Start recording
xcrun simctl io "$DEVICE_UDID" recordVideo --codec=h264 --force test.mov &
RECORD_PID=$!
sleep 1

# 6. Launch app and run tests
xcrun simctl launch "$DEVICE_UDID" "$BUNDLE_ID"
# ... test actions here ...

# 7. Take screenshot
xcrun simctl io "$DEVICE_UDID" screenshot result.png

# 8. Stop recording
kill -INT $RECORD_PID
wait $RECORD_PID 2>/dev/null

# 9. Cleanup
xcrun simctl shutdown "$DEVICE_UDID"
xcrun simctl delete "$DEVICE_UDID"
```

### CI considerations

- Always use UDIDs, not names, to avoid conflicts in parallel runs
- Use `xcrun simctl delete unavailable` to clean up stale devices
- Set `SIMCTL_CHILD_` env vars for test configuration
- Use `--console` or `--stdout`/`--stderr` to capture app output for test assertions
- For parallel testing, create multiple simulators with unique names/UDIDs

## Swift Programmatic Access

For building Swift drivers, interact with simulators via `Process`:

```swift
import Foundation

func simctl(_ args: String...) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw SimulatorError.commandFailed(String(data: data, encoding: .utf8) ?? "")
    }
    return String(data: data, encoding: .utf8) ?? ""
}

// Usage
let devices = try await simctl("list", "devices", "available", "-j")
```

### Parsing simctl JSON output

All `simctl list` commands support `-j` for JSON output. Key structures:

- **Devices:** `{"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-18-0": [{"udid": "...", "name": "...", "state": "Booted"}]}}`
- **Runtimes:** `{"runtimes": [{"identifier": "...", "name": "iOS 18.0", "isAvailable": true}]}`
- **Device types:** `{"devicetypes": [{"identifier": "...", "name": "iPhone 16 Pro"}]}`

## XCTest / XCUITest Integration

For running XCTest-based UI tests on simulators:

```bash
# Build for testing
xcodebuild build-for-testing \
  -scheme MyApp \
  -destination "platform=iOS Simulator,id=<device-udid>"

# Run tests
xcodebuild test-without-building \
  -scheme MyApp \
  -destination "platform=iOS Simulator,id=<device-udid>" \
  -resultBundlePath ./TestResults.xcresult

# Run specific test
xcodebuild test-without-building \
  -scheme MyApp \
  -destination "platform=iOS Simulator,id=<device-udid>" \
  -only-testing:MyAppUITests/LoginTests/testLoginFlow
```

## Accessibility Inspector (for AI-driven testing)

The Accessibility Inspector (`/Applications/Xcode.app/Contents/Applications/Accessibility Inspector.app`) can inspect the accessibility hierarchy of simulator apps. For programmatic access to the accessibility tree, use XCUITest's element query APIs:

```swift
// XCUITest accessibility queries (for reference)
let app = XCUIApplication()
app.launch()
let buttons = app.buttons
let labels = app.staticTexts
let textFields = app.textFields

// Accessibility tree snapshot
let snapshot = try app.snapshot()
```

For AI-driven testing, the accessibility tree provides element labels, types, frames, and values — the key data for LLM-based interaction planning.
