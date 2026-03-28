---
name: android-emulator
description: Comprehensive guide for Android Emulator and ADB — AVD management, app lifecycle, UI automation (tap/swipe/text), screenshots, video recording, permissions, and debugging.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-05 |
| ADB Version | 1.0.41 (36.0.2) |
| Android SDK | Platform-tools + cmdline-tools latest |
| Source | `adb help`, `emulator -help`, `avdmanager` (authoritative) |

### Update checklist
- [ ] Run `adb help` and diff against documented commands
- [ ] Check `adb shell input` for new input methods
- [ ] Check [Android Studio Release Notes](https://developer.android.com/studio/releases) for emulator changes
- [ ] Verify `uiautomator dump` XML schema hasn't changed

# Android Emulator Skill

Expert-level reference for automating Android Emulator and device interactions using `adb`, `emulator`, and `avdmanager`.

## When to use

Use this skill when working with Android Emulators or devices for:
- Creating, starting, managing AVDs (Android Virtual Devices)
- Installing, launching, and inspecting apps via ADB
- UI automation (tap, swipe, type, key events)
- Capturing screenshots and recording video
- Managing permissions, settings, and device state
- Debugging and log inspection

## Project Alignment (mobile-testing repo)

In this repository:

- Keep emulator/device lifecycle and app management on host-side (`adb` wrappers).
- Keep taps/swipes/typing/query actions on companion-side instrumentation.
- Implement parity at intent level; optional capabilities must return explicit unsupported errors.

## Prerequisites

```bash
# Required SDK tools (typically at ~/Library/Android/sdk/)
export ANDROID_HOME=~/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin

# Verify installation
adb version
emulator -version
avdmanager list avd
sdkmanager --list
```

## AVD (Android Virtual Device) Management

### List and create AVDs

```bash
# List existing AVDs
emulator -list-avds
avdmanager list avd

# List available device definitions
avdmanager list device

# List available system images
sdkmanager --list | grep "system-images"

# Download a system image
sdkmanager "system-images;android-35;google_apis_playstore;arm64-v8a"

# Create an AVD
avdmanager create avd \
  -n "TestDevice" \
  -k "system-images;android-35;google_apis_playstore;arm64-v8a" \
  -d "medium_phone"

# Create with SD card
avdmanager create avd \
  -n "TestDevice" \
  -k "system-images;android-35;google_apis_playstore;arm64-v8a" \
  -d "medium_phone" \
  -c 512M

# Delete an AVD
avdmanager delete avd -n "TestDevice"
```

### Start emulator

```bash
# Start emulator (opens GUI window)
emulator -avd TestDevice

# Start headless (no window — for CI)
emulator -avd TestDevice -no-window -no-audio

# Start with specific options
emulator -avd TestDevice \
  -no-snapshot-load \    # cold boot
  -no-boot-anim \       # skip boot animation
  -gpu swiftshader_indirect \  # software GPU for CI
  -no-audio \
  -memory 2048

# Wipe user data on start
emulator -avd TestDevice -wipe-data

# Quit after boot (useful for CI setup validation)
emulator -avd TestDevice -quit-after-boot 120

# Start with port assignment
emulator -avd TestDevice -port 5554
```

### Wait for boot completion

```bash
# Wait for device to be online
adb wait-for-device

# Wait for boot to fully complete
adb shell getprop sys.boot_completed
# Returns "1" when ready

# Full boot wait script
adb wait-for-device
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 1
done
echo "Device booted"
```

### Multiple devices

```bash
# List connected devices
adb devices -l

# Target specific device by serial
adb -s emulator-5554 shell ...
adb -s <serial> shell ...

# Target the only emulator (-e) or only USB device (-d)
adb -e shell ...  # emulator
adb -d shell ...  # USB device
```

## App Management

### Install and uninstall

```bash
# Install APK
adb install app.apk

# Install with options
adb install -r app.apk          # replace existing, keep data
adb install -t app.apk          # allow test APK
adb install -g app.apk          # grant all runtime permissions
adb install -r -t -g app.apk    # combine flags

# Install multiple APKs (split APKs)
adb install-multiple base.apk split_config.apk

# Uninstall
adb uninstall com.example.myapp

# Uninstall but keep data
adb uninstall -k com.example.myapp
```

### Launch, stop, and manage apps

```bash
# Start an activity
adb shell am start -n com.example.myapp/.MainActivity

# Start with intent action
adb shell am start -a android.intent.action.VIEW -d "https://example.com"

# Start and wait for launch to complete
adb shell am start -W -n com.example.myapp/.MainActivity

# Force stop an app
adb shell am force-stop com.example.myapp

# Clear app data
adb shell pm clear com.example.myapp

# Send a broadcast
adb shell am broadcast -a com.example.myapp.MY_ACTION

# Start a service
adb shell am startservice -n com.example.myapp/.MyService
```

### Inspect apps

```bash
# List all installed packages
adb shell pm list packages

# List third-party packages only
adb shell pm list packages -3

# Get APK path
adb shell pm path com.example.myapp

# Get app info (dumps all package details)
adb shell dumpsys package com.example.myapp

# Get current activity
adb shell dumpsys activity activities | grep mResumedActivity

# Get current window focus
adb shell dumpsys window | grep mCurrentFocus
```

## UI Automation (Input Commands)

### Tap, swipe, type

```bash
# Tap at coordinates (x, y)
adb shell input tap 500 1200

# Long press (swipe from point to same point with duration)
adb shell input swipe 500 1200 500 1200 1000  # 1000ms hold

# Swipe (x1, y1, x2, y2, duration_ms)
adb shell input swipe 500 1500 500 500 300      # swipe up
adb shell input swipe 500 500 500 1500 300      # swipe down
adb shell input swipe 800 800 200 800 300       # swipe left
adb shell input swipe 200 800 800 800 300       # swipe right

# Type text
adb shell input text "hello%sworld"  # %s = space
adb shell input text "hello"

# Key events
adb shell input keyevent KEYCODE_HOME
adb shell input keyevent KEYCODE_BACK
adb shell input keyevent KEYCODE_ENTER
adb shell input keyevent KEYCODE_TAB
adb shell input keyevent KEYCODE_DEL          # backspace
adb shell input keyevent KEYCODE_MENU
adb shell input keyevent KEYCODE_APP_SWITCH   # recent apps
adb shell input keyevent KEYCODE_POWER
adb shell input keyevent KEYCODE_VOLUME_UP
adb shell input keyevent KEYCODE_VOLUME_DOWN
adb shell input keyevent KEYCODE_WAKEUP

# Paste from clipboard
adb shell input keyevent KEYCODE_PASTE

# Select all text
adb shell input keyevent KEYCODE_MOVE_HOME
adb shell input keyevent --longpress KEYCODE_SHIFT_LEFT KEYCODE_MOVE_END
```

### Common key codes

| Key Code | Value | Description |
|----------|-------|-------------|
| KEYCODE_HOME | 3 | Home button |
| KEYCODE_BACK | 4 | Back button |
| KEYCODE_ENTER | 66 | Enter/Return |
| KEYCODE_DEL | 67 | Backspace |
| KEYCODE_TAB | 61 | Tab |
| KEYCODE_SPACE | 62 | Space |
| KEYCODE_DPAD_UP | 19 | D-pad up |
| KEYCODE_DPAD_DOWN | 20 | D-pad down |
| KEYCODE_DPAD_LEFT | 21 | D-pad left |
| KEYCODE_DPAD_RIGHT | 22 | D-pad right |
| KEYCODE_POWER | 26 | Power button |
| KEYCODE_MENU | 82 | Menu |
| KEYCODE_SEARCH | 84 | Search |
| KEYCODE_APP_SWITCH | 187 | Recent apps |

## Screenshots & Video Recording

### Screenshots

```bash
# Capture on device then pull
adb shell screencap /sdcard/screenshot.png
adb pull /sdcard/screenshot.png ./screenshot.png
adb shell rm /sdcard/screenshot.png

# Direct capture to local machine (faster)
adb exec-out screencap -p > screenshot.png
```

### Video recording

```bash
# Record video (max 180 seconds, Ctrl+C to stop)
adb shell screenrecord /sdcard/recording.mp4

# With options
adb shell screenrecord --size 720x1280 /sdcard/recording.mp4
adb shell screenrecord --bit-rate 4000000 /sdcard/recording.mp4   # 4 Mbps
adb shell screenrecord --time-limit 30 /sdcard/recording.mp4      # 30 sec max
adb shell screenrecord --verbose /sdcard/recording.mp4

# Pull recording to local machine
adb pull /sdcard/recording.mp4 ./recording.mp4
adb shell rm /sdcard/recording.mp4
```

### Programmatic recording pattern

```bash
# Start recording in background
adb shell screenrecord --time-limit 120 /sdcard/test_recording.mp4 &
RECORD_PID=$!

# ... run your tests ...

# Stop recording
adb shell pkill -INT screenrecord
sleep 2

# Pull the file
adb pull /sdcard/test_recording.mp4 ./test_recording.mp4
adb shell rm /sdcard/test_recording.mp4
```

## UI Hierarchy (Accessibility Tree)

### UIAutomator dump

```bash
# Dump UI hierarchy to XML
adb shell uiautomator dump /sdcard/ui_dump.xml
adb pull /sdcard/ui_dump.xml ./ui_dump.xml

# Direct dump to stdout
adb exec-out uiautomator dump /dev/tty

# The XML contains elements with attributes:
#   class, text, resource-id, content-desc, bounds, clickable, enabled, focused, etc.
```

### Window and activity info

```bash
# Current activity and task stack
adb shell dumpsys activity activities | grep -E "mResumedActivity|topResumedActivity"

# Current window focus
adb shell dumpsys window | grep -E "mCurrentFocus|mFocusedApp"

# Window hierarchy
adb shell dumpsys window windows

# Accessibility nodes (verbose)
adb shell dumpsys accessibility
```

**For AI-driven testing:** The `uiautomator dump` XML provides the accessibility tree — element types, text, content descriptions, resource IDs, and bounds (coordinates). This is the primary data source for LLM-based UI interaction planning.

## Permissions

```bash
# Grant a runtime permission
adb shell pm grant com.example.myapp android.permission.CAMERA
adb shell pm grant com.example.myapp android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.example.myapp android.permission.READ_CONTACTS
adb shell pm grant com.example.myapp android.permission.WRITE_EXTERNAL_STORAGE
adb shell pm grant com.example.myapp android.permission.RECORD_AUDIO
adb shell pm grant com.example.myapp android.permission.READ_PHONE_STATE

# Revoke a permission
adb shell pm revoke com.example.myapp android.permission.CAMERA

# Install with all permissions granted
adb install -g app.apk
```

## Device Settings

```bash
# Get a setting
adb shell settings get system screen_brightness
adb shell settings get global airplane_mode_on
adb shell settings get secure location_mode

# Set a setting
adb shell settings put system screen_brightness 255
adb shell settings put global airplane_mode_on 1
adb shell settings put system screen_off_timeout 600000  # 10 min
adb shell settings put global stay_on_while_plugged_in 3  # stay awake

# Display settings
adb shell wm size                     # get screen size
adb shell wm size 1080x1920           # set screen size
adb shell wm size reset               # reset to default
adb shell wm density                  # get density
adb shell wm density 480              # set density
adb shell wm density reset            # reset
```

## Location Simulation

```bash
# Enable mock locations in developer settings (required)
adb shell appops set com.example.myapp android:mock_location allow

# Using emulator console for location
# Connect to emulator console
# telnet localhost 5554
# geo fix <longitude> <latitude> [<altitude>]

# Via adb (requires mock location app or root)
# Most reliable: use emulator -avd ... and the extended controls
```

### Emulator console commands

```bash
# Connect to emulator console
adb emu geo fix -122.4194 37.7749    # longitude, latitude (note: lon first!)

# Or via telnet
echo "geo fix -122.4194 37.7749" | nc localhost 5554
```

## File Transfer

```bash
# Push file to device
adb push local_file.txt /sdcard/remote_file.txt

# Push directory
adb push ./local_dir /sdcard/remote_dir

# Pull file from device
adb pull /sdcard/remote_file.txt ./local_file.txt

# Pull with compression
adb pull -z brotli /sdcard/large_file.zip ./large_file.zip

# Sync (push only changed files)
adb push --sync ./local_dir /sdcard/remote_dir
```

## Logging

```bash
# Stream logcat
adb logcat

# Filter by tag
adb logcat -s MyApp:V

# Filter by priority (V=Verbose, D=Debug, I=Info, W=Warn, E=Error, F=Fatal)
adb logcat *:E

# Filter by app PID
adb logcat --pid=$(adb shell pidof com.example.myapp)

# Clear logcat buffer
adb logcat -c

# Save to file
adb logcat -d > logcat.txt

# Format options
adb logcat -v time          # timestamp
adb logcat -v threadtime    # timestamp with thread info
adb logcat -v json          # JSON format (for parsing)

# Filter with grep
adb logcat | grep -i "error\|exception\|crash"

# Dump and exit
adb logcat -d
```

## Networking

```bash
# Port forwarding (host:8080 → device:8080)
adb forward tcp:8080 tcp:8080

# Reverse port forwarding (device:8080 → host:8080)
adb reverse tcp:8080 tcp:8080

# List forwards
adb forward --list
adb reverse --list

# Remove forwards
adb forward --remove tcp:8080
adb forward --remove-all
adb reverse --remove-all

# Connect to device over TCP/IP (wireless)
adb tcpip 5555
adb connect <device-ip>:5555
adb disconnect <device-ip>:5555
```

## Device Info & State

```bash
# Get device properties
adb shell getprop ro.build.version.sdk       # API level
adb shell getprop ro.build.version.release   # Android version
adb shell getprop ro.product.model           # device model
adb shell getprop ro.product.manufacturer    # manufacturer
adb shell getprop persist.sys.language       # language
adb shell getprop persist.sys.timezone       # timezone

# Battery info
adb shell dumpsys battery

# Memory info
adb shell dumpsys meminfo com.example.myapp

# CPU info
adb shell dumpsys cpuinfo

# Network info
adb shell dumpsys connectivity
adb shell ifconfig

# Disk usage
adb shell df
```

## Automation Patterns

### Full test workflow example

```bash
#!/bin/bash
set -euo pipefail

AVD_NAME="TestDevice"
PACKAGE="com.example.myapp"
APK_PATH="./app/build/outputs/apk/debug/app-debug.apk"
ACTIVITY="$PACKAGE/.MainActivity"

# 1. Start emulator in background
emulator -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim &
EMU_PID=$!

# 2. Wait for boot
adb wait-for-device
while [ "$(adb shell getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 2
done
echo "Emulator booted"

# 3. Disable animations (makes tests more reliable)
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

# 4. Keep screen on
adb shell settings put global stay_on_while_plugged_in 3
adb shell input keyevent KEYCODE_WAKEUP

# 5. Install app with all permissions
adb install -r -t -g "$APK_PATH"

# 6. Start recording
adb shell screenrecord --time-limit 120 /sdcard/test.mp4 &

# 7. Launch app
adb shell am start -W -n "$ACTIVITY"
sleep 2

# 8. Run test actions
adb shell input tap 540 960       # tap center
adb shell input text "test"       # type text
adb shell input keyevent KEYCODE_ENTER

# 9. Take screenshot
adb exec-out screencap -p > result.png

# 10. Dump UI hierarchy for analysis
adb exec-out uiautomator dump /dev/tty > ui_dump.xml

# 11. Stop recording and pull
adb shell pkill -INT screenrecord
sleep 2
adb pull /sdcard/test.mp4 ./test.mp4

# 12. Grab logs
adb logcat -d > logcat.txt

# 13. Cleanup
adb shell am force-stop "$PACKAGE"
adb emu kill
wait $EMU_PID 2>/dev/null
```

### CI considerations

- **Disable animations:** Critical for test reliability (window_animation_scale, transition_animation_scale, animator_duration_scale all set to 0)
- **Headless mode:** Use `-no-window -no-audio -no-boot-anim`
- **GPU rendering:** Use `-gpu swiftshader_indirect` for software rendering in CI
- **Snapshot caching:** Boot once, save snapshot, use `-no-snapshot-save` for fast starts
- **Parallel runs:** Use `-port` to assign different ports per emulator
- **API level compatibility:** Test against minimum supported API level
- **Timeouts:** Always set explicit timeouts; emulator boot can take 30-120s in CI

## Swift Programmatic Access

```swift
import Foundation

func adb(_ args: String...) async throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/Users/maniramezan/Library/Android/sdk/platform-tools/adb")
    process.arguments = Array(args)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw ADBError.commandFailed(String(data: data, encoding: .utf8) ?? "")
    }
    return String(data: data, encoding: .utf8) ?? ""
}

// Usage
let devices = try await adb("devices", "-l")
let screenshot = try await adb("exec-out", "screencap", "-p")
```

### Parsing UI hierarchy XML

The `uiautomator dump` output contains elements like:

```xml
<node index="0" text="Sign In" resource-id="com.example:id/login_button"
      class="android.widget.Button" package="com.example.myapp"
      content-desc="Sign in to your account" checkable="false" checked="false"
      clickable="true" enabled="true" focusable="true" focused="false"
      bounds="[200,800][880,920]" />
```

Key attributes for AI-driven testing:
- **text**: Visible text content
- **resource-id**: Developer-assigned identifier
- **content-desc**: Accessibility description
- **bounds**: `[left,top][right,bottom]` — use center for tap coordinates
- **clickable/enabled/focusable**: Interaction capabilities
- **class**: Widget type (Button, TextView, EditText, etc.)
