## Record a session that generates a good test

A session that "passed" is not the deliverable — the deliverable is a plan that
`amoo generate test` turns into a readable, complete test. The MCP `initialize`
instructions carry the same list (kept in sync by `MCPInstructionsAlignmentTests`);
follow it whether you drive amoo through MCP or the CLI.

**Canonical workflow:** `start_session` → drive the app under test → `end_session`
(which compiles the history and writes `plan.json`) → inspect `plan.json` and its
warnings → `amoo generate test`. `compile_session_to_plan` is an *optional
preview* you may run while the session is still open; it is never a required step.

1. **Start from deterministic launch state.** If the caller gave you launch
   arguments or environment (skip-onboarding, reset-state, a mock-server URL),
   pass them to `start_session` / `amoo companion start`. The plan records
   them under `requirements` and the generated test replays them in `setUp`. Don't
   tap through onboarding you were handed a flag to skip.
2. **Resolve every target semantically before acting.** `describe_screen` to
   orient, `find_elements id=…` / `contains_text=…` to confirm the specific
   element, then act with `tap_element` / `set_text` / `swipe_in_direction`.
   Selector priority: accessibility id → visible label → text filter → (last
   resort) coordinates.
3. **List-row gestures — one canonical workflow.** For a tap or swipe on one row
   of a list (SwiftUI `.swipeActions`, per-row buttons): `find_elements` for the
   row, then call `swipe_in_direction` with that row's `element_id` (preferred) or
   `element_label`. The companion fails rather than guessing on an ambiguous
   id/label, the recorded step keeps the row's identity, and the compiler emits an
   element-scoped gesture — `groceriesTaskRow.swipeLeft()`, not `app.swipeLeft()`.
   Only when the row has no stable id or label, fall back to a coordinate
   `swipe`/`tap`: the recorder binds it to the element you just resolved
   (`SessionAction.gestureTarget` / `observedElements`) so codegen still recovers
   the row. Never read coordinates off a screenshot (pixels vs points).
4. **Verify every mutation with an explicit semantic assertion.** After a delete,
   `assert_absent` (or `find_elements` + count) on a text/label. After an
   add, `assert_visible` the new element. An unverified mutation compiles to an
   action with nothing asserting on it.
5. **End the session, then read the plan warnings before generating.**
   `end_session` already compiles the recorded history and writes `plan.json` —
   there is no separate `compile_session_to_plan` step in the canonical flow (it
   is an optional preview you can call earlier, while the session is still open,
   and it does not change the plan `end_session` writes). Inspect `plan.json` and
   every `compiledPlan.warnings` entry. An `excluded` / incomplete-plan warning
   means a required **app-under-test** action was dropped: treat that as a
   **failed** codegen result, not a finished test. Fix the recording (add an
   identifier, drive through an addressable ancestor, re-record) rather than
   reaching for `--allow-incomplete`. amoo's own lifecycle calls
   (`start_session`, `end_session`, `compile_session_to_plan`,
   `get_session_report`) are never recorded as app actions and never emit a
   trailing `XCTFail` for uncompiled work.
6. **Review the generated variable names and markers.** Names come from labels and
   inferred roles; a UUID/hash/record-id-derived name, or an
   `XCTFail("Uncompiled required action …")`, means the plan was incomplete — go
   back to step 5. Give the test a descriptive name from the requested flow with
   `amoo generate test --test-name "…"`.
7. **Report back** the plan path, the generated file path, every compiled-plan
   warning, and any limitation (mock server required, transient system-UI steps,
   approximate selectors). If you passed `--allow-incomplete`, say which steps are
   missing and why.

### Acceptance scenario

> *Skip onboarding, open Tasks, delete Groceries, add Groceries, generate XCTest.*

A correct run of that request looks like:

- Session started with the app's skip-onboarding / reset-state launch environment
  (not tapped through).
- `find_elements` resolves the "Groceries" task-list row **before** the
  swipe; the recorded `swipe_in_direction` carries that row's `element_id`.
- Generated code contains `groceriesTaskRow.swipeLeft()` (or `groceriesRow`) —
  **never** a UUID-derived name like `a40fb286E7ca…Row`.
- Two identically-labelled elements with different roles get distinct semantic
  names (a catalog row `groceriesTaskRow` vs a picker option
  `groceriesPresetOption`), never `groceries` / `groceries2`.
- `setUp` sets `app.launchEnvironment[...]` for each provided flag.
- A delete assertion (`assert_absent` / `waitForAbsence` on "Groceries")
  and an add assertion (`assert_visible` / `waitForHittability` on "Groceries").
- No `--allow-incomplete` — and if the agent used it, an explicit note of which
  steps are missing and why.

`IOSSessionCodegenRegressionTests` locks this in end-to-end.

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

**Skip most of that finalize pass with an app-owned test context.** A checked-in
`test-context.json` gives generation the host's `baseClass`, `appFactory`,
`harnessLaunchesApp`, `imports`, reusable `helpers`, and a `selectorExpressions`
id catalog — see [`docs/test-context.md`](../../../docs/test-context.md). Supply it
at generate time (`--context`), when recompiling a report
(`amoo generate plan --report report.json --context … --out …`), or through MCP at
`start_session` / `compile_session_to_plan` (`context_path` / `context_json`,
persisted with the session so an `end_session` recompile keeps it).

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
latency alone. Measured against a sample app, taps requested 0.05s apart recorded at
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

Use `selectorExpressions` and `idLookupTemplate` to translate recorder IDs into
the repository's identifier catalog without making that catalog an Amo default:

```json
{
  "imports": ["AppUITestSupport"],
  "baseClass": "AppUITestCase",
  "appFactory": "forAutomatedTesting(skipOnboarding: false, resetState: true)",
  "harnessLaunchesApp": true,
  "idLookupTemplate": "app.element(id: {{id}})",
  "selectorExpressions": {
    "0A0D-raw-recording-id": "AppUIAutomationID.task.chore"
  }
}
```

Mapped expressions are caller-owned code and are used only for IDs listed in the
context. Unmapped IDs retain the portable default lookup. Redacted values block
export until a caller replaces them with an approved fixture/helper; Amo never
emits a `<redacted, …>` marker as executable test data.

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

### Generated variable names are semantic-first

The exporter names each local from the semantics the recording already carries,
**never** from an opaque identifier token. Priority (`TestIdentifierNaming.elementVariableBase`):

1. the accessible label / visible text;
2. a role inferred from the element type or a role-shaped accessibility-ID
   segment (`tab`, `button`, `row`, `field`, `toggle`, …), plus a semantic
   container segment when a label anchored the name;
3. the last meaningful (non-opaque, non-role) identifier segment;
4. `element`.

UUIDs, hashes, numeric record ids and other opaque trailing segments are dropped
entirely — a collision is resolved by a short deterministic numeric suffix
(`groceriesTaskRow`, then `groceriesTaskRow2`), never by falling back to the
id. Examples:

| accessibility id | label | generated name |
| --- | --- | --- |
| `app.tab.tasks` | `Tasks` | `tasksTab` |
| `app.task_list.create_button` | `New Task` | `newTaskButton` |
| `app.task_list.row.<uuid>` | `Groceries` | `groceriesTaskRow` |
| — | `Delete` | `deleteButton` |
| `sample.home.feed.sectionTitle.most_loved` | — | `mostLovedSectionTitle` |

The selector remains the stable test contract; the local name is a human-readable
review aid. Repeated references to the same selector reuse one binding; distinct
colliding selectors receive numeric suffixes. If you see a UUID- or
hash-derived name in generated code, the plan was incomplete or a `find_elements`
observation was missing before the gesture — fix the recording, don't rename by
hand.
