# App-owned test context

`amoo generate test` emits a standalone XCUITest / Espresso file. By default that file subclasses
`XCTestCase`, constructs a bare `XCUIApplication()`, and drives every element through a
`descendants(matching:)` query. A host app usually wants generated tests to fit an existing test
target instead — its own base class, its launch/assertion helpers, its identifier catalog.

A **test context** is a small, checked-in JSON file that carries exactly that. Generation never
guesses any of it: a helper is used only when an operation explicitly names it, and a selector is
rewritten only when the recorded accessibility id is listed in `selectorExpressions`.

## Supplying it

| Path | How |
| --- | --- |
| CLI, at generate time | `amoo generate test --plan plan.json --context test-context.json` |
| CLI, at recompile time | `amoo generate plan --report report.json --context test-context.json --out out/` |
| MCP, at session start | `start_session` with `context_path` (a file path) or `context_json` (inline) |
| MCP, at compile time | `compile_session_to_plan` with `context_path` / `context_json` |

A context supplied through MCP is **persisted with the session**, so a later `end_session`
auto-compile and `amoo generate test` reuse it without a CLI-only `--context` override. An explicit
`compile_session_to_plan` context refines whatever `start_session` seeded (set fields win; unset
fields are kept). The plan's embedded `testContext` is what `amoo generate test` reads; a
`--context` flag on that command still overrides it.

## Schema

```jsonc
{
  // Modules to `import` at the top of the generated file. Helper-level imports are merged in.
  "imports": ["AppTestSupport"],

  // Base class for the generated XCTestCase. Default: "XCTestCase".
  "baseClass": "AppUITestCase",

  // Expression that CONSTRUCTS the app under test. Default: "XCUIApplication()".
  // The emitter still calls `app.launch()` itself unless `harnessLaunchesApp` is true.
  "appFactory": "makeApp()",

  // true when the base class or app factory already launches the app, so the generated
  // setUp must not launch it a second time. Declared, never inferred from `baseClass`.
  "harnessLaunchesApp": true,

  // Reusable helpers. A helper is emitted ONLY for an operation whose planner explicitly
  // bound it (or whose call shape `amoo generate test` could match to it). `{{arg}}`
  // placeholders are filled from the operation's arguments and string-literal escaped.
  "helpers": [
    { "name": "signIn",
      "callTemplate": "signIn(email: {{email}}, password: {{password}})",
      "imports": ["SignInKit"] }        // optional; omit when the helper needs no module
  ],

  // Recorded accessibility id  ->  a repository-owned identifier expression. When an
  // operation's selector id matches a key here, the generated lookup uses the expression
  // instead of a raw string literal.
  "selectorExpressions": {
    "app.task_list.row.chore": "AppUIAutomationID.task.chore"
  },

  // Optional lookup template for mapped ids. Default keeps the standalone XCUITest shape:
  //   "app.descendants(matching: .any)[{{id}}]"
  "idLookupTemplate": "app.element(id: {{id}})",

  // iOS only: "phone" or "pad". The generated test skips itself on the other device class
  // (`import UIKit` plus an `XCTSkipUnless` on the user interface idiom, before the launch), so
  // an iPhone recording does not tap controls an iPad layout does not have. Omit for no guard.
  "requiredIdiom": "phone"
}
```

Every field is optional; an empty `{}` is valid and behaves like no context at all. Fields added
after a context file was first checked in (`harnessLaunchesApp`, helper `imports`) decode as their
default when absent, so an older file keeps working unchanged.

## Example

A host app with a `AppUITestCase` base class that already launches the app, and an `assertRowVisible`
helper:

```json
{
  "imports": ["AppTestSupport"],
  "baseClass": "AppUITestCase",
  "appFactory": "AppUITestCase.launchedApp()",
  "harnessLaunchesApp": true,
  "helpers": [
    { "name": "assertRowVisible", "callTemplate": "assertRowVisible({{contains_text}})" }
  ],
  "selectorExpressions": {
    "app.task_list.create_button": "AppUIAutomationID.taskList.createButton"
  }
}
```

Generated `setUp` then constructs the app through the factory and does **not** add `app.launch()`;
the create-button tap resolves through `AppUIAutomationID.taskList.createButton`; and any
operation the planner bound to `assertRowVisible` emits that call rather than an inline predicate.

## Complete XCUITest example

The minimal context every host app needs — a support module, a base class, an app factory, and
`harnessLaunchesApp` — with no helpers or id catalog yet:

```json
{
  "imports": ["MyUITestSupport"],
  "baseClass": "MyAppUITestCase",
  "appFactory": "makeTestApplication()",
  "harnessLaunchesApp": true,
  "helpers": [],
  "selectorExpressions": {},
  "idLookupTemplate": null
}
```

Supplied at `start_session` (`context_json` above, or `context_path` to a checked-in file), it is
persisted with the session, folded into `plan.json` by `end_session`, and `amoo generate test`
emits (for a one-step `tap app.tab.tasks` / `assert_visible app.tab.tasks` plan):

```swift
import XCTest
import MyUITestSupport

/// Generated by amoo from the Studio test "Context Example". Edit freely — this file has no
/// dependency on amoo or the companion apps once generated.
final class ContextExampleTest: MyAppUITestCase {
    private let defaultTimeout: TimeInterval = 5
    private lazy var app = makeTestApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        // no app.launch() — harnessLaunchesApp is true, so MyAppUITestCase / the factory owns it
    }

    override func tearDownWithError() throws {
        // failure screenshot + UI-hierarchy attachments …
        try super.tearDownWithError()
    }

    // waitForExistence / waitForHittability / waitForAbsence / replaceText / pressBack helpers …

    func testContextExample() throws {
        let tasksTab = app.descendants(matching: .any)["app.tab.tasks"]
        waitForHittability(tasksTab, named: "tasksTab", timeout: 5.0)
        tasksTab.tap()

        waitForHittability(tasksTab, named: "tasksTab", timeout: 5.0)
    }
}
```

The complete, byte-exact output is the checked-in golden
`Tests/TestCodeGeneratorTests/Fixtures/context-example-ios.swift.golden` (input:
`context-example-ios.json`); `GoldenFixtureTests` fails if the emitter drifts from it.

Points the emitter guarantees for this context:

- `import MyUITestSupport` is added (helper-level `imports` would be merged in too).
- the class subclasses `MyAppUITestCase`, not `XCTestCase`.
- `harnessLaunchesApp: true` suppresses the emitter's own `app.launch()` — exactly once; omit the
  key and the emitter launches.
- `setUpWithError` / `tearDownWithError` always chain to `super`, so the base class's own
  setup/teardown still runs.
- `idLookupTemplate: null` and empty `selectorExpressions` keep the portable
  `app.descendants(matching: .any)[<id>]` lookup for every selector.

`XCUITestContextTests.testDocumentedXCUITestContextSchemaGeneratesTheExpectedScaffold` and
`SessionCodegenContextTests.testStartSessionPersistsTheDocumentedXCUITestContextSchema` lock this
example to the implementation.

## Shared TestCommons helpers

Projects that link `TestCommonsXCUI` to their UI test target can opt in by adding
`"TestCommonsXCUI"` to the context's `imports`. Direct emitter callers can instead
use `XCUITestEmitter(useTestCommons: true)`. Generated Swift 6 tests then use the
shared existence, value, and absence waits and screenshot/hierarchy diagnostics.
The generated test class is isolated to `@MainActor`. Existing generation stays
standalone unless explicitly opted in.

Set `TESTCOMMONS_XCUI_MODULE_PATH` to an iOS Simulator build's module directory
when running the generator's shared-helper compilation test. That test checks the
actual generated source with Swift 6 and the simulator SDK.

## Repository integration profile

`amoo init --save` discovers Swift UI-test harness evidence and writes `amoo.md` alongside
`AGENTS.md`. It creates no tests, adapter class, or Generated directory and preserves an existing
profile. Review and complete uncertain conventions using the listed source files. A fenced
`amoo-context` block holds the export bindings; no separate JSON file is required.

Recording (`start_session`) and CLI plan/test generation discover the nearest `amoo.md` from the
working directory. Recording snapshots its bindings into the session. A discovered Swift harness
is marked `targetPlatform: "ios"` so it is not automatically applied to Android recordings or exports. An embedded plan context
wins over automatic discovery; explicit context arguments win over both. `--context` and
`context_path` also accept the Markdown profile. Malformed profiles report an error.

For a harness that owns and launches its application, add these bindings:

```amoo-context
{
  "imports": ["JotUIIdentifiers"],
  "baseClass": "JotUITestCase",
  "harnessOwnsApp": true,
  "harnessLaunchesApp": true,
  "factoryOverride": "super.makeApplication().usingLanguage(\"en\", locale: \"en_US\")",
  "waitBindings": {
    "waitForHittability": "waitForExistence({{element}})",
    "waitForExistence": "waitForExistence({{element}})",
    "waitForAbsence": "waitForAbsence({{element}})"
  },
  "timeoutExpressions": {"default": "UITestConstants.timeout"},
  "assertionBindings": {},
  "relaunchHelper": "relaunchApplication()",
  "selectorExpressions": {"app.tab.habits": "JotUIAutomationID.Tab.habits"},
  "idLookupTemplate": "app.element(id: {{id}})"
}
```

Use the actual catalog IDs, helper signatures, and timeout constants from the receiving repository.
`harnessOwnsApp` suppresses the property and isolates the subclass to `@MainActor`.
`factoryOverride` supplies the expression returned by `override func makeApplication()`;
customization runs before the base class launches during setup. Wait bindings replace generated
wait calls and remove their equivalent private implementations. Templates receive Swift expressions
for `{{element}}` and `{{timeout}}`. Timeout keys are recorded milliseconds or `default`.
Assertion bindings are keyed by Studio assertion tool and additionally accept a string-literal
`{{value}}` (or `{{contains}}` for substring expectations). A binding that drops a recorded
expectation is rejected. Only configure bindings whose semantics match the recorded assertion.

Document onboarding, initial reset, language, persistence, and relative calendar rules in the
profile. Apply the appropriate factory expression and relative catalog mappings for the scenario;
the deterministic compiler cannot infer relative date intent from a literal recorded date.
Adjacent successful `device_terminate_app` / `device_launch_app` calls for the session app,
without launch overrides, compile to `relaunch_application`. Generation requires `relaunchHelper`
and emits that call, preserving harness state rules. Failed pairs, other app IDs, and custom launch
configuration remain excluded for review. Authored plans may also use `relaunch_application`.

Export provenance is stored in a `provenance/` directory beside the input plan, outside the exported
Swift/Kotlin directory. Keep input plans and recordings in tool storage. Compile and run generated
source in the receiving target before treating it as validated.
