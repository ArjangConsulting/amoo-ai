# Device tools

What `amoo device <tool>` and `amoo flow` do, tool by tool. Machine-readable discovery, launch
receipts, required coverage and measured execution are in [AI-driven verification](verification.md).

amoo is a CLI. It does not run an AI provider: an agent (or a person, or a script) leases a device and
calls tools, and amoo answers each call with one JSON object.

## Prerequisites

```bash
amoo env up --platform ios --device <udid> --app-id <bundle-id> --json
amoo device --runtime-id <runtime> --json <tool> key=value ...
amoo env down --runtime-id <runtime> --json
```

`env up` leases a simulator or emulator, starts its companion on a free port, and prints the
`runtime_id`; `--runtime-id` (or `AMOO_RUNTIME_ID`) then supplies the platform, device and port to
`amoo device` and `amoo flow`. `amoo device` with no tool lists every tool and its arguments, and
`amoo capabilities --tool <tool>` prints one schema. Both companions bind IPv4 loopback; remote network
exposure is not a supported deployment mode. Physical devices need USB forwarding; see
[prerequisites](prerequisites.md).

Install the CLI with `brew install arjangconsulting/tap/amoo`; no source checkout is required.

## Adaptive Android emulator controls

Use `device_wake` when a screenshot reports `screen_state=off`. It verifies that the display is
awake and reports `locked` when the keyguard is still present. It does not dismiss the lock screen
or relaunch the app. Android puts a locked display back to sleep after about 10 seconds, so a
`locked` result is not stable: unlock the device (or keep it unlocked) before layout checks.
`device_wake unlock=true` additionally dismisses a swipe (or no-credential) keyguard and verifies the
display is on. When the device is protected by a PIN, pattern or passphrase it fails with
`credential_required`; amoo never types or reads credentials, so ask the person holding the device to
unlock it and retry. This applies to physical devices as much as emulators.
Follow it with an app visibility assertion before evaluating layout.

Android `device_health` independently probes the host ADB transport, an Android shell command,
and companion RPC. `failure_scope=device_execution` identifies an unresponsive guest even when
the ADB server and companion listener respond. Timeout results include these independent probes
when available; app and render readiness remain separate.

`device_shutdown` waits for the emulator process to exit and its ADB serial to disappear. A
shutdown acknowledgement is insufficient. If verification times out, amoo reports failure and
does not claim the AVD is safe to restart. Boot also checks host registrations before launching
another instance of an AVD that is absent from ADB. No AVD data or lock files are deleted.
If the console is unresponsive, shutdown can send SIGTERM to the host PID after rechecking that
it still identifies the selected emulator. It still verifies both process exit and ADB disconnect.

For a snapshot-related emulator failure, stop its runtime, verify `device_shutdown`, then use
`amoo env up --platform android --avd <name> --cold-boot`. This bypasses snapshot loading and
saving while preserving installed apps and their data. The flag rejects already running AVDs.

`set_posture posture=closed|half_opened|opened` changes a foldable emulator's hinge posture
and waits for Android's committed device state. `set_display_preset preset=phone|unfolded|tablet`
changes a resizable emulator's display, verifying the dimensions and density advertised by that
emulator. Both tools are available through `amoo device` and in flows.
Re-query elements after each transition because the layout, active display, and coordinates can change.

These controls use the [Android emulator console commands](https://developer.android.com/blog/posts/emulator-control-for-adaptive-app-development).
They reject physical devices and unsupported emulator configurations. A successful result verifies
device configuration; use app assertions or WebView observations to check playback and document
continuity. Native XCUITest/Espresso export currently excludes these host-side configuration steps
with a warning that blocks complete test generation.

Android hierarchy captures are serialized within the companion. When a child disappears during a
capture or no window root is available, the companion makes up to three complete capture attempts
with a short backoff for window registration. Exhausted retries remain an error rather than an
empty element list, so absence assertions cannot pass on an incomplete tree.

## Reusable test flows

Keep deterministic smoke tests in a checked-in `*.amoo.json` file and run the whole sequence over
one companion connection:

```bash
amoo flow Examples/sign-in.amoo.json
```

Each step names a normal device tool. `${name}` in an argument value (anywhere in the string)
resolves from the flow's `"vars"`, then `--var name=value`, then the process environment, so
credentials do not enter source control. Argument values may be JSON strings, numbers or booleans.
The runner stops at the first failed action or assertion and prints the verified result for every
completed step; a step (or the whole flow) with `"on_error": "continue"`, or `--continue-on-error`,
keeps going and the exit code is still 1 if anything failed. `--continue-on-error` overrides step
and flow settings. A step with `"optional": true` is
reported when it fails but never stops the flow or fails the run; use it only for a step whose outcome
does not matter to the check, never to make a failing check pass on some devices. `"repeat": N` runs a step N times. `scroll_to_element`, `tap_element`
and `screenshot` steps already wait for the screen to settle, so a `wait_for` with `idle` after them only
adds calls; a `tap_element` whose next step is an assertion or `wait_for` skips its own after-tap read.
See [`Examples/sign-in.amoo.json`](../Examples/sign-in.amoo.json) for the format.

Flow-only steps cover what used to need a shell loop:

| Step | Arguments | Does |
| --- | --- | --- |
| `wait` | `duration_ms` or `seconds` | Pauses. |
| `wait_for` | `id`/`label`/`contains_text`, `timeout_ms` (default 10000) | Waits for the element (an `assert_visible` with a timeout). |
| `wait_for` | `idle: true`, `stable_ms` (500), `timeout_ms` | Waits until the screen stops changing — first frame after a launch, end of a rotation. |
| `screenshot` | `name` (optional) | Saves `<--output-dir>/NN-<name>.png`, numbered by step. |

One flow can run on several devices at once: `amoo flow f.amoo.json --devices UDID1:22111,UDID2:22112
--output-dir out/` runs them in parallel, writes screenshots to `out/<device>/`, and ends with a
`PASS`/`FAIL` line per device (`${device}` is available as a variable). An iOS entry without
`:port` uses the port derived from its UDID. Flow-only steps are dropped (or, for `wait_for` on an
element, turned into `assert_visible`) by `generate plan --from-flow`.

### Running several companions

`amoo companion start --detach` registers each process, so `amoo companion list` shows pid, platform,
port, state, device and app, and `amoo companion stop --port N` / `--device UDID` / `--all` stops
exactly those (never `pkill`, which also stops other sessions' companions). A process that restarts
its runner now reclaims the port the old runner app left bound instead of failing with "owned by
another companion process".

### Tap safety and scrolling

`tap_element` reads the hierarchy before tapping and refuses a target that another control (a
keyboard key, a sheet) is painted over, that a clipping container (a tab pill, a scroll view) cuts
off, or whose tap point is off-screen. The check is on by default but best effort: it gives up after
`hittable_timeout_ms` (1500) and taps unchecked, so a very dense screen never slows every call.
`check_hittable=true` makes it required; `false` skips it. It always reports
`foreground_changed` when the tap left the app (Siri, a system sheet), and compares the screen before
and after the tap — within `effect_timeout_ms` (1500), `check_effect=false` to skip — so a tap that
left the semantic snapshot unchanged reports `semantic_change=false` and `observable_change=false`.
After the tap it re-reads the hierarchy until it differs (compared by the companion's content digest)
and takes `target_state` from that same read, so a changed screen costs no extra snapshot. A tap that
changes nothing visible waits out the 800ms settle window; pass `expect_id`, `expect_label` or
`expect_contains_text` (`expect_absent=true` to wait for it to go away, `expect_timeout_ms`, default
5000) and the call instead waits on the device for exactly that element and returns as soon as it
shows (or, with `expect_absent`, is gone), reporting `expected_effect_met` and `expectation_status`.
With `expect_absent`, the element is read before the tap; if it was already gone the status is
`already_satisfied` and `expected_effect_met` is omitted, because waiting proves nothing. In a flow,
a missed or unreadable expectation fails the step. A companion that does not
advertise `query.waitForElement.absent` is polled from the host instead. `check_effect` is skipped when an expectation is given.
Pixel changes and app postconditions remain unverified; unchanged semantics do not prove identical screenshots.
Occlusion is first inferred from accessibility frames and traversal order, which cannot see paint
order: a SwiftUI `.overlay` can come before the list it floats over in the accessibility tree, so the
rows read as covering it. A covered or clipped block found that way is put to the companion's
`HitTest` RPC (XCUITest `isHittable` on iOS) before the tap is refused. When the device finds the
target on top, the tap proceeds and the result carries `hit_test: "hittable"` and a note naming the
dismissed blocker. When it agrees, the refusal says so. When no hit test is available (Android, a
companion that predates the RPC) or it cannot resolve the element, the refusal says the target "may
not receive" the tap. If it is drawn on top, retry with `check_hittable=false` and assert the
intended outcome. An off-screen tap point is plain geometry and is refused without a hit test.
`scroll`'s direction names where to scroll (`down` reveals content below; `swipe_in_direction`
names the finger's direction instead). `scroll_to_element` scrolls until a target is on screen, and exports
(a swipe-until-hittable loop in XCUITest, `scrollTo()` in Espresso, `performScrollTo()` in Compose);
`dismiss_keyboard` only taps an unambiguous, visible, enabled button labeled `Hide keyboard` or
`Dismiss keyboard`, then verifies that the keyboard disappeared. Without a dedicated dismissal
control it fails without acting. It never sends Return or Escape, taps a generic Done button, or
swipes, since those can submit a form or close a sheet. Use `tap_element` with an explicit app
control when you intend that action. Deadlines are 12s per call; set `AMOO_RPC_TIMEOUT_SECONDS` (1–600) when a very
large accessibility tree needs longer.

### Drag and drop, and pinch

`drag` presses its source, holds there (`hold_ms`, default 800 — above the ~500ms both iOS and
Android wait before lifting an item for drag-and-drop), moves onto its target over `duration_ms`
(default 1000), dwells briefly, and releases. Name the source by `id` / `label` / `contains_text`
(with `parent_id`, `index` / `first`) and the target by the same keys prefixed `to_`; it refuses a
covered or off-screen source the way `tap_element` does. `from_x`/`from_y` and `to_x`/`to_y` drive a
coordinate end instead.

`pinch` takes `scale` (above 1 zooms in, below 1 zooms out) and an element, a point (`x`/`y`), or
neither for the screen centre. Both companions synthesize the two finger paths directly, fitted
inside the screen, so an extreme scale is clamped rather than sent off-screen. The fitting lives in
`AmooCore/PinchGesture.swift` (mirrored by the Android companion's `PinchGesture.kt`).

Both export only when every end was an element: XCUITest `press(forDuration:thenDragTo:…)` and
`pinch(withScale:velocity:)`, Compose `performTouchInput`, and for Espresso two small `ViewAction`s
(`dragOnto`, `pinch`) emitted into the test, which inject touches through `UiController`. A
coordinate end is excluded from the plan with a reason saying what to record instead. A drop or
zoom is an outcome, so assert it afterwards.

## Reviewing screenshots

`amoo flow ... --output-dir shots/` (or `take_screenshot output=`) leaves a folder of PNGs. Two
offline commands turn it into something reviewable, with no extra tooling:

```bash
amoo shots montage shots/ --columns 4          # one captioned contact sheet: shots/contact-sheet.png
amoo shots diff baseline/ shots/ --out diffs/  # per-file same / CHANGED / MISSING / SIZE / NEW, exit 1 on any change
```

`diff` counts a pixel as changed when any colour channel moves by more than `--tolerance` (8), and
fails a file when more than `--threshold` (0.1%) of its pixels changed; `--out` writes a red overlay
of each failing file. Both need CoreGraphics, so they run on macOS only.

## Generating tests from a flow

Author the sequence as a flow, then compile and generate:

```bash
amoo generate plan --from-flow Examples/sign-in.amoo.json --test-name SignIn --out out/
amoo generate test --plan out/plan.json --out out/
```

A tap's `expect_id` / `expect_label` compiles to the assertion that follows it. To make the generated
file fit a host test target (its base class, launch and assertion helpers, identifier catalog), pass
an app-owned test context with `--context`; see [`docs/test-context.md`](test-context.md). A recorded
`report.json` from an earlier release still recompiles with `amoo generate plan --report`.

## Efficient and reliable clients

### Reducing calls without weakening verification

Load `plugins/amoo/skills/driving-amoo/SKILL.md` first and its references only when needed.
Contributor skills are not required to operate the device.

`describe_screen` derives context, actionable elements, and `screen_token` from a single hierarchy
observation. Tokens detect changes in labels, values, geometry, visibility, and tree order within
companion hierarchy limits. They are change hints, not durable selectors or proof of readiness.
Use explicit assertions as postconditions. Mutations reject ambiguous matches; refine with IDs
and `parent_id`, or, when several elements are truly indistinguishable (iPadOS 27's top tab bar
exposes each tab twice), pick one with `index` (0-based, in the device's order) or `first: true` on
`find_elements`, `tap_element` and the `assert_*` tools. A recorded pick becomes
`.element(boundBy:)` / `.firstMatch` in the generated XCUITest, a `withIndex(...)` matcher in
Espresso, and `onAllNodes(...)[n]` in Compose (`set_text` / `fill_field` take no pick yet). `find_elements` also prints each element's current `value` (never for secure fields,
and never written to the session report) and, for a whole-screen listing, hides repeated-label static
text and scroll bars unless `include_noise=true`. A timeout can occur after a device action started: inspect before retrying.

#### Selector constraints

`id`, `label` and `contains_text` are **constraints, and all of them must match**. `assert_visible
id=day.30 contains_text="Range end"` passes only for an element that has that identifier *and* a
label containing the text; a correct identifier with the wrong text fails. `parent_id` scopes the
search to that element's descendants before any constraint applies, and `index` / `first` pick among
the survivors afterwards. `description` / `field_description` are natural-language guesses, not
constraints, so combining one with an exact field is rejected with `invalid_argument` rather than
ignored. For `swipe_in_direction`, `element_id` and `element_label` follow the same rule. (Before,
the host used the first of `id`, `label`, `contains_text` and dropped the rest, so such a call
passed on the identifier alone; the companions have always matched every field they were sent.)
`parent_id` was likewise a no-op on a real device: the request carried the parent, but neither
companion read it, so a day "under" a button that had no children still matched. The host now
applies the scope itself from the companion's view hierarchy — the parent must resolve to exactly
one element (several is `ambiguous_selector`, none matches nothing), only its descendants are
candidates, and if the hierarchy cannot be read the call fails with `scope_unavailable` instead of
quietly running unscoped.

Android reports resource IDs as the app spells them and uses the content description as an ID
when the node has no resource ID. When both a resource ID and a content-description alias match
the same selector, amoo prefers the resource ID. Multiple matching resource IDs still require a
more specific selector or an explicit pick.

The same constraints reach `report.json`, `plan.json` and every emitter: XCUITest chains
`.matching(identifier:)` and `NSPredicate` filters, Espresso uses `allOf(…)` with
`isDescendantOfA(…)`, and Compose joins matchers with `and` and `hasAnyAncestor(…)`.

#### Asserting selection

`assert_selected` (`id`/`label`/`contains_text`/`description`, `expected=true|false`, default
`true`, `timeout_ms`, `parent_id`, `index`/`first`) polls until an **existing** element's selected
state equals `expected`. An absent element fails even for `expected=false`; the failure reports
`selector`, `expected`, `observed` (`selected`, `unselected`, `not_found`) and
`resolution_failed`. Duplicate matches are `ambiguous_selector`, as for every other assertion. A
device that reports no selected state returns `selected_state_unsupported`; visibility, enabled
state and `assert_value` are never substituted (they cannot see the selected trait). iOS reports
the state; Android does not yet, so Android recordings cannot contain the assertion and the
Espresso/Compose emitters refuse a hand-written one.

`find_elements` prints each element's `selected` state, but that is an observation: it is never
compiled into an assertion. When a recorded observation read a selected state, the plan carries a
`selected_state_not_asserted` warning naming the action and the state, so the gap is visible.

`find_elements` and `list_apps` default to 50 results;
use `limit` and `next_offset` while `has_more` is true. Offsets query live state, so keep the screen
stable while paging and restart if it changes. Hierarchy output defaults to 200 nodes with an
explicit truncation marker. Truncated output cannot establish absence. Prefer `get_screen_context`
and scoped queries over screenshots. `take_screenshot` saves to `saved_path` (or `output`) without an
inline image by default, at one pixel per point/dp; pass `return_image=true` only when the model must
see pixels, since an inline image is re-read on every later turn. A project's
[`screenshots`](credentials.md#screenshot-defaults) defaults in `amoo.config.json` (set by `amoo init`)
can shrink that size or turn inline images on; a call's own `scale`/`return_image` wins. Use available local tools such as Python/ffmpeg for pixel diffs,
bounds or centroids, and view only a small crop when visual interpretation is necessary. To look at one
control, pass its `id`, `label` or `contains_text` (with `parent_id`, `index` or `first` as for a tap):
the saved image is cut to that element plus `padding` points (default 8), and `crop_origin_points`
maps a position in the crop back to gesture points. For a transient state, batch the action and an immediate
`take_screenshot` with `settle_timeout_ms=0` in one `run_steps` call. Set `check_effect=false` on
a triggering `tap_element` to skip its post-tap hierarchy reads. For tighter timing, use a
coordinate `tap` from freshly queried geometry to avoid its foreground-app observation too.
Capture before asserting the eventual outcome, and use a cold fixture when cached data would
skip loading. Batching removes client round trips; device and recording latency still apply,
so it does not guarantee capture within a subsecond window. Reusable deterministic action
sequences can use `amoo flow` to avoid a model round trip per action. Keep focused inspections
within 20 actions where practical without dropping required checks.

Calls serialize per device: a lease taken by `amoo env up` holds an OS file lock, so a second process
cannot drive the same device, and a call that times out may still finish on the device.
Required hittability inspection must succeed before a tap; best-effort taps report
`hittability_checked=false` when inspection was unavailable (omitted under `response_mode=compact`,
where a missing field means `false`).

Known entered secrets and sensitive launch metadata are redacted in tool results. Screenshots can still contain sensitive pixels: choose
appropriate fixture data. Do not put secrets in test names or app-owned context files.

Audit results describe the inspected screen and include per-rule evidence coverage. No findings
is not a whole-app security certification; deep-link validation requires scenario evidence.

For a short known sequence, `run_steps` accepts an array of up to 20
`{"tool":"…","arguments":{…}}` objects, including `take_screenshot` observations. Actions,
assertions and observations execute in order under the same device queue, stop at the first failure,
and each attempted step is recorded once. Screenshot steps save to a file
(`output` or a temporary `saved_path`); batch responses contain compact summaries, never inline images. Nested batches,
lifecycle calls and per-step session overrides are rejected before execution. Per-step timeouts
are capped at 10 seconds and gesture durations at 3 seconds. Completed actions are not rolled back.
Use normal discovery calls to decide the sequence first; batch responses contain compact summaries.

### Testing a release executable

Run `python3 scripts/ci/cli-smoke.py /absolute/path/to/amoo [--arch arm64|x86_64]` before distributing a
build. It runs `version`, the tool listing, a schema lookup and a device-free flow on the exact binary,
so a crash only the release compiler produces fails before a user's first call.

### Android accessibility state and diagnostics

`assert_checked` reads native checkable/checked state. `assert_state_description` compares native
stateDescription with exactly one of `expected` or `contains`; empty expected text remains valid.
These properties are independent of selected state and editable value. Missing provider support
returns `state_property_unsupported`.

`check_accessibility` runs the checks the project opted in to in `amoo.config.json` (via `amoo init`),
once at default display settings and again in each opted-in configuration (dark mode, largest text,
increased contrast), then restores every setting. It fails unless every check the platform can run
passed; `exclude_checks` / `exclude_elements` with `exclude_reason` leave false positives out of one
call. See [accessibility checks](accessibility-checks.md).

`audit_accessibility_native` supports Google ATF on Android and Apple native audits on iOS, with
explicit per-category coverage and optional `output` PNG highlights. Its reply names up to five
issues (category, label, id, frame); `structuredContent.issues` keeps every one. By default it reports
findings without failing; `fail_on_issues=true` makes it an assertion that fails unless the audit
ran and found no issues, which is how a flow step fails on an accessibility regression. `test_talkback` observes
keyboard focus traversal and actual synthesis requests; `assert_talkback_speech` additionally requires
one JSON speech expectation per move. Both restore original service/TTS settings. TalkBack capture
is silent and does not verify audible output or touch gestures. See
[provider requirements and limits](accessibility-and-voiceover.md#android-native-and-talkback-providers).

`device_health [app_id=...]` independently probes device transport and companion RPC under bounded
deadlines. Optional app checks report foreground identity and semantic readiness separately from
render readiness. Transport failures remain environment failures, not app assertion failures.

## Capture and run reliability

`device_install_app` validates the artifact before installing: the app identifier and executable for
`.app` bundles, archive signatures for APK/IPA files. An invalid artifact fails before device work.
Concurrent builds can continue after the snapshot is complete.

Screenshots report `capture_suspect` for nearly black, white, transparent or uniform frames, plus
`capture_analysis`, `screen_state`, `foreground_app_id` and native `viewport` dimensions. This is
an advisory image-quality check, not an app-failure verdict. Unsupported decoding reports
`analysis_unavailable` and omits `capture_suspect`. Posture/display operations return the same
device context; verified posture alone does not establish an unlocked screen or app readiness.

Action responses and recorded diagnostic evidence carry `outcome_status`: `dispatched`,
`target_state_confirmed`, `target_state_mismatch` or `inconclusive`. Tap dispatch and semantic
change do not establish the requested app outcome. Missing selectors include bounded, ranked
accessible candidates with roles, preserving parent scope and the original assertion constraints.

Use one caller UUID as `run_id` across all attempts, or set `AMOO_RUN_ID` across CLI processes.
`amoo usage report` aggregates every tool request,
including validation failures, recovery and unfinished calls; persistent tool telemetry lives under
the session root's `runs/` directory. Counts cover instrumented device-tool requests, not shell commands.
Text payload bytes exclude image blocks; wire response bytes include base64 and JSON overhead.
Inline image bytes/pixels and saved evidence bytes/pixels are separate. `model_token_usage=null`
means no model-provider token usage is available; none is inferred from bytes or pixels.

Delegated checks default to `output=<path> return_image=false`, with selected thumbnails or
`amoo shots montage` contact sheets returned for review. Pause playback through the app when
stable content is needed, and replay recorded navigation flows for repeatable setup.

### Clean verification starts and setup failures

Installing over an existing app preserves its data. To start clean, `device_uninstall_app` before
`device_install_app`; this clears app-local data, but iOS Keychain and remote account state can survive.

`amoo env list --json` shows each runtime's owner, `expires_at` and `expired`. Listings are advisory;
`env up` checks ownership again.

Explicit assertions accept `precondition=true`. A mismatch records `preconditionFailed`, which
leaves that requirement incomplete and derives blocked/partial coverage. A passing setup assertion
alone does not complete a requirement. A later behavior assertion supplies its actual verdict.



`tap_element` includes bounded `target_state` observations (selected, checked, state_description,
value) after dispatch with effect checks enabled. Missing or ambiguous targets return null.
Observations do not create assertions or complete coverage; batch explicit assertions with the tap
when proof is required. Set check_effect=false to omit this read for latency-sensitive captures.
