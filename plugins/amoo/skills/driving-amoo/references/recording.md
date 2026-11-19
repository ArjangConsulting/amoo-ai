## Author a flow that generates a good test

A flow that passed is not the deliverable: the deliverable is a plan that `amoo generate test` turns
into a readable, complete test.

**Workflow:** write the working sequence as a flow (`*.amoo.json`) → run it with `amoo flow` until it
passes twice → `amoo generate plan --from-flow <flow> --out <dir>` → read `plan.json` and its warnings →
`amoo generate test --plan <dir>/plan.json --out <dir>`.

1. **Start from deterministic launch state.** Put the caller's launch arguments and environment
   (skip-onboarding, reset-state, a mock-server URL) on the flow's `device_launch_app` step. The plan
   records them under `requirements` and the generated test replays them in `setUp`. Don't tap through
   onboarding you were handed a flag to skip.
2. **Resolve every target semantically.** Selector priority: accessibility id → visible label → text
   filter → (last resort) coordinates. Selector fields are constraints: `id`, `label` and
   `contains_text` must **all** match.
3. **List-row gestures.** For a swipe or tap on one row, give `swipe_in_direction` that row's
   `element_id` (preferred) or `element_label`. The compiler then emits an element-scoped gesture,
   `groceriesTaskRow.swipeLeft()`, not `app.swipeLeft()`. Never read coordinates off a screenshot.
   `drag` takes the source as `id`/`label` and the target with `to_` keys; `pinch` takes `scale`. Both
   compile to element-scoped steps only when every end was an element. Assert the outcome afterwards.
4. **Verify every mutation explicitly.** After a delete, `assert_absent`; after an add,
   `assert_visible`. A selection is asserted with `assert_selected expected=true|false`, the only step
   that becomes an `.isSelected` check: an observation is never turned into an assertion. A tap's
   `expect_id` / `expect_label` is a postcondition too: keep it, and check the generated test waits for it.
5. **Read the plan warnings before generating.** Each `compiledPlan.warnings` entry carries a
   `category` (`inspection_omitted`, `observation_approximated`, `selected_state_not_asserted`,
   `assertion_preserved`, `assertion_weakened`, `assertion_unsupported`, `action_excluded`,
   `selector_constraint_discarded`) plus the step, selector and state. An `excluded` /
   incomplete-plan warning means a required app action was dropped: treat that as a **failed**
   codegen result. Fix the flow (add an identifier, drive through an addressable ancestor) rather than
   reaching for `--allow-incomplete`.
6. **Review the generated names and markers.** A UUID- or hash-derived name, or an
   `XCTFail("Uncompiled required action …")`, means the plan was incomplete: go back to step 5. Name
   the test after the requested flow with `--test-name "…"`.
7. **Report back** the flow, plan and generated file paths, every compiled-plan warning, and any
   limitation (mock server required, approximate selectors). If you passed `--allow-incomplete`, say
   which steps are missing and why.

### Acceptance scenario

> *Skip onboarding, open Tasks, delete Groceries, add Groceries, generate XCTest.*

- The flow launches with the app's skip-onboarding / reset-state environment (not tapped through).
- The swipe on the "Groceries" row carries that row's `element_id`; the generated code contains
  `groceriesTaskRow.swipeLeft()`, never a UUID-derived name.
- Two identically labelled elements with different roles get distinct semantic names
  (`groceriesTaskRow` vs `groceriesPresetOption`), never `groceries` / `groceries2`.
- `setUp` sets `app.launchEnvironment[...]` for each provided flag.
- A delete assertion (`waitForAbsence` on "Groceries") and an add assertion.
- No `--allow-incomplete`, or an explicit note of which steps are missing and why.

## Export tests: `generate test` emits a skeleton, not a finished test

Use `amoo generate test --plan path/to/plan.json` to turn a compiled plan into a
standalone XCUITest or Espresso test. Generated code has no run-time
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
id catalog — see [`docs/test-context.md`](https://github.com/ArjangConsulting/amoo-ai/blob/main/docs/test-context.md). Supply it
at plan time (`amoo generate plan --from-flow <flow> --context … --out …`) or at generate
time (`--context`).

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
  against staging" — if the flow used a mock-server base URL (or
  `requirements` names one), the generated test needs that mock running, and the
  plan should say so.

For an app with established test helpers, pass an app-owned context file:

```sh
amoo generate test --plan path/to/test.amootest --context amoo.test-context.json
```

Check in the context with the test target. Current binaries also accept amoo.md with a
fenced amoo-context JSON block and discover the nearest profile from cwd. A prose-only
Markdown file is guidance and cannot be passed as context. Check the pinned binary's help
for profile support, and pass an existing JSON file for versions without it. A planner can
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
