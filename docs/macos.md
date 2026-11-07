# Driving this Mac (`--platform macos`, experimental)

amoo can drive apps on the desktop of the Mac it runs on (available since 0.4.0). It uses the same XCUITest companion and
gRPC protocol as iOS, built for macOS (`AmooCompanionMac` in `CompanionApps/iOS/project.yml`).

## Setup

macOS asks for one thing before UI tests may drive the desktop: Automation Mode must be allowed to
start without a password prompt. Check it, and fix it once if needed:

```bash
amoo preflight --platform macos
# if macos.automation-mode fails, run this in a terminal (it asks for your password once):
sudo automationmodetool enable-automationmode-without-authentication
```

The Mac must be unlocked while a session runs: behind the lock screen no app window can be seen or
driven, so a session refuses to launch the app while the screen is locked.

Release installs ship a prebuilt companion (`CompanionApps/iOS/prebuilt/macosx`); a source checkout
builds it on first use.

## Using it

Pass `platform: macos` to `start_session` (or `--platform macos` on the CLI), with the app's bundle
id and, optionally, a `.app` to run:

```json
{"platform": "macos", "app_id": "com.example.notes", "build_path": "/path/to/Notes.app"}
```

- The Mac is chosen only when `macos` is named. It never appears in a platform-less device pick or
  `list_devices` without `platform: macos`, so nothing drives your desktop by accident. Its device
  id is `mac`.
- `build_path` registers the bundle with Launch Services in place (nothing is copied) and that exact
  build is launched. Launching quits a running instance first, so launch arguments and environment
  reach a fresh process.
- Launches pass `-ApplePersistenceIgnoreState YES`, as XCTest does, so the app opens a fresh window
  on the current Space. A restored window can land on another Space, where neither accessibility nor
  XCUITest can see it. Pass the flag yourself to choose otherwise.
- Only one session can drive the Mac at a time. `amoo env up` does not lease it.
- The companion listens on port 22086 by default.

## Geometry

Screenshots, element frames and gesture points are in points relative to the top-left corner of the
display the app's main window is on, as with a phone's screen. Screen info reports that display's
size in points and its backing scale (2 on Retina). On a multi-display Mac this follows the window.

## Gestures

| Tool | On a Mac |
| --- | --- |
| `tap`, `tap_element` | A click |
| `double_tap` | A double click |
| `long_press` | A press and hold |
| `swipe`, `drag` | A mouse drag between the points |
| `scroll`, `swipe_in_direction` | The scroll wheel (a mouse drag would select text instead) |

Not available: `pinch`, `set_orientation`, `press_home`, location, permissions, appearance, screen
recording and `amoo device stream`. Uninstalling an app and shutting the device down are refused,
because the device is your own Mac.

## Generating a test

A macOS session records and generates like any other: `start_session` with `platform: macos`, drive
and assert, `end_session`, then `amoo generate test`. The result is an XCUITest class, and it runs in
a macOS UI-testing bundle whose target application is the app you recorded.

| Recorded | Generated |
| --- | --- |
| `tap_element` | `element.click()` |
| `set_text` | click, select all (`typeKey("a", .command)`), delete, then `typeText` |
| `scroll`, `swipe_in_direction`, `scroll_to_element` | `scroll(byDeltaX:deltaY:)` on the element, else on `app.windows.firstMatch` (the app element has an infinite frame) |
| `drag` | `source.click(forDuration:thenDragTo:)` |
| `pinch`, `press_back` | Generation stops with an `unsupportedOnTarget` error; a Mac has neither |

Waits, assertions, `type_text` and screenshots are the same as on iOS. The scroll deltas follow the
companion: content moves the way the gesture does, so `scroll(down)` is a negative `deltaY`, and
`distance` (default 300) is points of wheel travel.

A raw point `swipe` is a mouse drag on a Mac, not a scroll, so it is not turned into
`swipe_in_direction` as it is on a phone. It stays an excluded step in the plan warnings; record
`scroll`, `swipe_in_direction` or `drag` instead. A `requiredIdiom` in the test context is refused,
since a Mac is neither a phone nor a tablet.

## Things to know

- You and amoo share one desktop. Switching apps or moving windows while a session runs can move the
  target app's window to another display or under another window. Queries follow the bound target
  app rather than whatever app is frontmost.
- The companion runs in the App Sandbox. It finds a target app by its running instance, so the app
  must be launched (by the session or by you) before it can be queried.

## Checking your setup

`scripts/run-e2e-macos.sh` is a one-minute smoke test of the whole path. It runs the preflight,
starts the companion, launches Calculator, checks the foreground app, takes a screenshot, taps
`7 × 6 =` and reads `42` back. Calculator has no documents, so nothing is left behind. The
screenshot shows your whole desktop, so it is deleted on exit unless `AMOO_MACOS_SMOKE_DIR` is set.
CI runs the same script in the `macos` job of `companions.yml`.
