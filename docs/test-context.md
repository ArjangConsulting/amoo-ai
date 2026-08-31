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
    "app.task_list.row.weed": "AppUIAutomationID.habit.weed"
  },

  // Optional lookup template for mapped ids. Default keeps the standalone XCUITest shape:
  //   "app.descendants(matching: .any)[{{id}}]"
  "idLookupTemplate": "app.element(id: {{id}})"
}
```

Every field is optional; an empty `{}` is valid and behaves like no context at all. Fields added
after a context file was first checked in (`harnessLaunchesApp`, helper `imports`) decode as their
default when absent, so an older file keeps working unchanged.

## Example

A host app with a `AppUITestCase` base class that already launches the app, and a `tapHabitRow`
helper:

```json
{
  "imports": ["AppTestSupport"],
  "baseClass": "AppUITestCase",
  "appFactory": "AppUITestCase.launchedApp()",
  "harnessLaunchesApp": true,
  "helpers": [
    { "name": "assertHabitVisible", "callTemplate": "assertHabitVisible({{contains_text}})" }
  ],
  "selectorExpressions": {
    "app.task_list.create_button": "AppUIAutomationID.habitCatalog.createButton"
  }
}
```

Generated `setUp` then constructs the app through the factory and does **not** add `app.launch()`;
the create-button tap resolves through `AppUIAutomationID.habitCatalog.createButton`; and any
operation the planner bound to `assertHabitVisible` emits that call rather than an inline predicate.
