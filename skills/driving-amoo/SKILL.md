---
name: driving-amoo
description: Drive a booted iOS simulator or Android emulator through the amoo CLI — startup sequencing, choosing the cheapest tool that answers the question, coordinate math, and the known unlabeled-element gap. For agents *using* amoo to verify app behaviour, not for agents developing amoo itself.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-08-17 |
| Last Updated | 2026-08-17 |
| Applies to | `amoo device`, `amoo companion`, `amoo flow` |

### Update checklist
- [ ] Diff the tool table below against `amoo device` (no args) — its listing is schema-checked by `DeviceHelpDriftTests`, this file is not
- [ ] Re-check the unlabeled-element rendering against `XCUITestBridge.collectMatchable` and the `find_elements` formatting in `ToolExecutor+Dispatch`

## What this is for

amoo is a CLI and MCP server for driving a booted simulator/emulator: taps, text
entry, element queries, screenshots, app lifecycle. Use it — not raw `simctl` /
`adb` / `xcodebuild` — whenever the task is *interacting with or inspecting a
running app*. Building the app and running its test suite stay `xcodebuild` /
`gradlew`.

Every example uses `amoo device`, the one-shot CLI form. `amoo mcp serve` exposes
the same tools to an MCP client, and `amoo device` with no arguments prints the
full tool list with every argument — read it once at the start of a session
rather than guessing.

## Start the companion before you need it, not when you need it

Device tools talk to a companion app (XCUITest on iOS, UIAutomator2 on Android)
over gRPC. `amoo companion start` builds and installs it if needed — cold, that
is minutes, and a source change to the companion forces a rebuild. It waits
until the companion is reachable and then backgrounds itself.

Do it as the first step, before the first query:

```sh
amoo preflight --platform ios                     # tooling check, once per machine
xcrun simctl install <udid> <path-to>.app         # or: amoo device device_install_app path=...
amoo companion start --platform ios --device <udid> --app <bundle-id>
amoo device --platform ios --device <udid> current_app
```

Starting it mid-flow — after you've installed the app and begun tapping — puts
that wait in the middle of the task, where it can outlast a command timeout and
look like a hang. If a device call fails with a connection error, amoo prints the
exact `companion start` line to run; that is a sequencing mistake, not a bug.

`--app <bundle-id>` binds the gesture target. Without it, taps still land, but
app-scoped queries have nothing to scope to.

## Pick the cheapest tool that answers the question

| Question | Tool | Cost |
| --- | --- | --- |
| Is the right app frontmost? | `current_app` | trivial |
| Did the expected screen/label appear? | `describe_screen`, `find_elements` | one accessibility snapshot |
| Did anything change at all? | `assert_screen_changed from_token=<token>` | one snapshot, polls internally |
| Interact with a labeled control | `tap_element`, `set_text`, `fill_field` | one snapshot + one gesture |
| What does this *look* like? | `take_screenshot output=<path>` | PNG capture + an image read |
| Where is this unlabeled icon? | `find_elements` with no selector | one snapshot; reports frames for unlabeled elements too |
| Nothing above can reach it | `tap x= y=` | cheap to run, easy to get wrong |

`describe_screen` and `find_elements` answer "did it work" faster and more
reliably than a screenshot, because they return text you can assert on. Reach for
a screenshot when the question is genuinely visual — layout, spacing, a pricing
table, an icon with no label — or when you need to show the user what happened.

Two habits worth keeping:

- **Don't poll in a loop.** One `describe_screen` after an action answers "did it
  change". If you need to wait for something, `assert_visible`,
  `assert_enabled`, and `assert_screen_changed` all take `timeout_ms` and poll
  internally — one call, not a sleep loop.
- **Don't shell out to `simctl io screenshot`.** `take_screenshot output=<path>`
  writes the same PNG to disk (and `scale=0.5` cuts it to roughly a quarter of
  the bytes, plenty for reading layout and state).

## Coordinates: points vs. pixels, and the second conversion

Gestures take **points**. Screenshots come back in **pixels** — points × device
scale, typically 3× on a modern iPhone. `take_screenshot` reports both sizes;
read them from the result instead of assuming a scale factor.

`tap` accepts `unit=pixels` (use a position straight off a screenshot) and
`unit=normalized` (a 0..1 fraction of the screen), which handles the conversion
for you.

The trap `unit=pixels` does *not* save you from: when you eyeball a coordinate
off an image **as it was rendered to you**, the viewer may have downscaled it
first. That needs two conversions, in order:

1. displayed pixel → original image pixel (multiply by the ratio the viewer reported)
2. original image pixel → points (divide by the device scale) — or skip this one by passing `unit=pixels`

Skipping step 1 taps the wrong place **and still reports success**: a tap that
hits no control is not an error. So a "successful" tap that changed nothing is
this bug until proven otherwise — verify with `describe_screen`, don't assume.

`find_elements` reports each match's centre in points, ready to hand to `tap` —
for unlabeled elements as well as named ones. Prefer it over reading pixels off
an image in every case: it skips both conversions and the guesswork with them.

## Unlabeled, icon-only controls

A close (X) button with neither label nor identifier — common in third-party SDK
paywalls and bare SF Symbol buttons — matches no selector, so `tap_element`,
`assert_visible`, and `find_element_by_description` cannot reach it. (That last
one, despite the name, is text matching over labels and identifiers, not vision.)

`find_elements` **with no selector** is the way in. It lists everything on
screen, unlabeled elements included, rendered as `[unlabeled] <type> at (x,y) pts
WxH`:

```sh
amoo device --platform ios --device <udid> find_elements
```

Named elements come first, then the unlabeled ones smallest-first — a small leaf
near the top of a sheet is almost always the icon button, a large one is the
backdrop. Tap the reported centre directly; it is already in points, so no
conversion and no screenshot:

```sh
amoo device --platform ios --device <udid> tap x=349 y=118
```

Pass `labeled_only=true` to get the old named-only listing when the full one is
noisy.

Two things worth trying before falling back to a coordinate:

- Guess the identifier: `find_elements id=close`, `contains_text=close`. App
  teams often set one even when the label is empty, and a named element stays
  correct when the layout shifts.
- If the control belongs to the app under test rather than a vendor SDK, the real
  fix is an `accessibilityIdentifier` on it — worth reporting back to the team.

Verify with `describe_screen` after the tap. A coordinate tap that hit nothing
still reports success.

## Repeatable flows

A sequence you'll run more than once belongs in a checked-in flow file rather
than a shell history:

```sh
amoo flow path/to/onboarding.amoo.json
```

Each step is a tool name plus its arguments — the same names and arguments as
`amoo device`. Prefer this over re-deriving a tap sequence per session.
