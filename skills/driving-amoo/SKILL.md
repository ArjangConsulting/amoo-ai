---
name: driving-amoo
description: Drive a booted iOS simulator or Android emulator through the amoo CLI — startup sequencing, choosing the cheapest tool that answers the question, coordinate math, and the known unlabeled-element gap. For agents *using* amoo to verify app behaviour, not for agents developing amoo itself.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-08-17 |
| Last Updated | 2026-08-31 |
| Applies to | `amoo device`, `amoo companion`, `amoo flow`, `amoo generate test` |

### Update checklist
- [ ] Diff the tool table below against `amoo device` (no args) — its listing is schema-checked by `DeviceHelpDriftTests`, this file is not
- [ ] Re-check the unlabeled-element rendering against `XCUITestBridge.collectMatchable` and the `find_elements` formatting in `ToolExecutor+Dispatch`
- [ ] Verify generated local names are selector-derived, readable lower camel case, and collision-safe
- [ ] Re-check the warning-triage table against `StudioPlanWarning.Kind` and `SessionPlanCompiler`

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

## Export tests: `generate test` emits a skeleton, not a finished test

Use `amoo generate test --plan path/to/test.amootest` to turn a compiled Studio
plan into a standalone XCUITest or Espresso test. Generated code has no run-time
dependency on amoo — but it is a **skeleton**. A repo-aware finalize pass is
expected before you commit it:

- Map every raw selector to the project's identifier catalog, and apply the
  project's variable-naming rules.
- Pick a test tier and the launch helper that tier uses.
- Turn dropped inspections into real assertions (see the warning table below).
- Wire the file into the build target and run it once.

**Never commit `generate test` output unchanged.**

### Triage the compiled-plan warnings

`generate test` refuses to emit when the plan has `excluded` steps unless you
pass `--allow-incomplete`. Don't reach for that flag — fix the root cause.

| Warning kind | Meaning | What to do |
| --- | --- | --- |
| `notApplicable` | An inspection-only step with no place in test code. | Usually nothing. **Except** when the reason says the inspection sat right before a state change but queried nothing assertable — that one is a missing assertion; write it by hand. |
| `approximate` | A selector or assertion was mapped loosely (e.g. text match instead of an id), a pre-transition inspection was compiled into an `assert_visible`, or a run of identical taps was collapsed. | Re-check the selector against the real element; confirm the synthesized assertion is the check you meant; see the repeated-taps note below. |
| `redacted` | A value was scrubbed by the recorder. | Hand-fill from a fixture before the test can run. |
| `excluded` | The step has no Studio-tool equivalent — usually a raw coordinate tap. | Fix the source: add an accessibility identifier to the element, or drive it through an addressable ancestor, then re-record. **Do not** `--allow-incomplete`. |

Steps the compiler could tell were system UI or a dismissable overlay carry
`transient: true`. If your build runs in a test/mock mode that suppresses those
prompts, drop the transient steps during finalize.

### Repeated taps: a tunable guess, with the evidence attached

Several identical taps close together are read as one person hammering an
unresponsive button, and collapse into a single guarded step. If they were
cumulative instead — a stepper, a quantity field, a keypad — the plan says 1 where
the recording said N. `flow.json` always keeps every tap.

**Why this can't be decided automatically.** Telling the two apart means knowing
whether the app responded to the first tap, and nothing a session records answers
that: `tap_element`'s recorded result is `Tapped verified element [id] label`,
built from the element tapped, so it is byte-identical whether the screen changed
or not. Timing is a proxy, and the populations overlap — a PIN entered quickly is
faster than a slow retry. So the window is a **default to tune per app**, not a
constant to trust.

Tune it with `retry_tap_interval_ms` on `compile_session_to_plan`, or
`AMOO_RETRY_TAP_INTERVAL_MS` for every compile. **Default is 300ms**, deliberately
below the ~450ms `tap_element` round-trip: an agent's taps are ~0.5s apart no matter
what it intends, so a larger window would collapse deliberate repeats on transport
latency alone. Measured against sample-app, taps requested 0.05s apart recorded at
0.576s and 0.678s — the same intent landing either side of a 600ms window.

The practical effect is that collapsing is **opt-in for agent-driven recordings**:
nothing is folded away silently, and you raise the window when you know a run was a
retry loop. A human driving a recorder directly can still produce genuine sub-300ms
hammering, which the default still catches.

- A hammered button kept as N steps → **raise** it.
- A deliberate repeat wrongly collapsed → **lower** it.

You don't have to guess at the value. Every run of 2+ identical taps is reported in
`retryRunObservations` with its gaps and whether it collapsed — including the runs
the window *rejected*, which are exactly the evidence for raising it. The text
summary lists the kept runs inline. Compile a few real sessions, look at where the
two clusters fall, and pick a value that separates them for this app.

A run whose taps are not uniformly fast is left intact rather than partially
collapsed: mixed cadence is ambiguous, and a partial collapse would change the tap
count on a guess.

## Repo-agnostic gotchas worth knowing before you finalize

- **Merged accessibility hides children.** `.accessibilityElement(children: .combine)`
  (SwiftUI) and merged Compose semantics collapse a subtree into one element, so
  a child button is only reachable by coordinate. If a coordinate tap landed
  inside a combined element, the fix is a per-child identifier in source — not a
  coordinate in the checked-in test.
- **Shared design-system components lack per-item ids.** Segmented pickers, top
  bars, paywalls from a component library have no identifier per item. Match by
  visible title and flag it `approximate`; a copy or locale change will break it.
- **Automated-test mode may block live network.** A project can hard-block
  outbound network in test mode. An un-mocked end-to-end plan cannot "just run
  against staging" — if the session used a mock-server base URL (or
  `requirements` names one), the generated test needs that mock running, and the
  plan should say so.

For an app with established test helpers, pass an app-owned context file:

```sh
amoo generate test --plan path/to/test.amootest --context amoo.test-context.json
```

The context is JSON and should be checked in with the test target. A planner can
bind a helper to an operation explicitly. Failing that, `generate test` binds one
itself only when the match is unambiguous:

- Every `{{placeholder}}` names an argument the operation actually carries.
- Every argument that *decides what the step does* — the selector (`id`, `label`,
  `contains_text`), plus `value` / `text` / `expected` / `direction` — is consumed
  by a placeholder. A `set_text` never binds to a helper that takes only the
  selector, because the text being typed would silently vanish. Incidental
  arguments like `timeout_ms` may go unused.
- The helper's name or call template carries the operation's verb as a **whole
  word** — a `tap_element` with an `id` binds to `tapById`; `tapCenter` is not a
  `set_text` helper just because it contains the letters `enter`.
- No other helper also qualifies.

Anything less certain is left unbound. Generation still rejects an explicitly
named helper that is unknown or missing a template argument.

The generated XCUITest's `setUpWithError` / `tearDownWithError` always chain to
`super`, so a supplied `baseClass` gets its own setup run.

By default the emitter adds `app.launch()` itself, so `appFactory` should
*construct* the app without launching it. If your base class or factory already
launches, say so explicitly with `"harnessLaunchesApp": true` — naming a
`baseClass` is not that declaration, since an app may name `XCTestCase` outright
and still rely on the emitter. Omitting the field keeps the emitter launching,
which is what every context file written before this flag existed expects.

```json
{
  "imports": ["AppTestSupport"],
  "baseClass": "AppUITestCase",
  "appFactory": "makeApp()",
  "helpers": [
    {
      "name": "signIn",
      "callTemplate": "signIn(email: {{email}}, password: {{password}})"
    }
  ]
}
```

Keep selectors descriptive. The exporter uses the selector to name local values,
so namespaced IDs retain their meaningful suffix and element role:

```swift
let mostLovedSectionTitle = app.descendants(matching: .any)[
    "sample.home.feed.sectionTitle.most_loved"
]
```

The selector remains the stable test contract; the local name is deliberately a
human-readable review aid. Repeated references receive a numeric suffix (for
example, `emailField2`) so the emitted test remains valid code.
