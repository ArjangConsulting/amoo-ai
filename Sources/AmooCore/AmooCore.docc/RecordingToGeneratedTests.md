# Recording to generated tests

Turn an exploratory device session into a reviewed plan and native test source.

## Overview

Live device interaction and offline source generation are separate stages. MCP records what
happened; SessionCompiler interprets that history; TestCodeGenerator emits native source from
the resulting plan. Compilation and emission do not require an LLM.

![Recorded calls become report.json, a compiled plan and replay flow, then native test source for the application's test target.](recording-pipeline.svg)

## Record evidence and intent

MCPServer records eligible tool calls as session actions, including intent and outcome.
Lifecycle tools such as `start_session`, `end_session`, and `compile_session_to_plan` are
control-plane operations and do not become application test steps. Diagnostics, failed probes,
and recovery attempts need interpretation rather than blind replay.

TestSession owns persistence to `report.json`. Offline readers and writers must use
`SessionReport.makeJSONEncoder()` and `makeJSONDecoder()` to preserve fractional timestamps;
losing that precision can change retry-collapse behavior.

## Compile the report

Ending an MCP session compiles its report and writes `plan.json` and `flow.json`.
`compile_session_to_plan` provides an optional preview while the session is open. The CLI can
also compile an existing report independently of MCP:

```bash
amoo generate plan --report report.json --out generated/
```

SessionCompiler maps recorded MCP tool names onto the StudioProtocol operation vocabulary,
classifies the recorded intent, and produces warnings where translation is incomplete.
For example, MCP's `assert_absent` maps to the plan's `assert_not_visible` operation.
The plan is the input to source generation; the flow artifact supports `amoo flow` replay.

## Supply application context and emit source

```bash
amoo generate test --plan generated/plan.json
```

StudioProtocol carries the plan and optional app-owned test context: base class, app factory,
launch behavior, imports, helper bindings, and identifier expressions. Supply that context when
your test target needs its own conventions. Generation does not infer arbitrary app helpers.

TestCodeGenerator emits XCUITest, Espresso, or Compose Espresso source. MCPServer does not depend
on TestCodeGenerator; the CLI composes the offline generation workflow. Review plan warnings and
resolve unsupported steps before treating the result as a regression test. The generated file
still needs to be integrated, compiled, and run in the application's test target.

## Find the right place to change behavior

| Change | Start here |
| --- | --- |
| Which calls are recorded and how intent is captured | MCPServer tool executor and recording extensions |
| Report encoding or storage | TestSession |
| Retry collapse, selector interpretation, and operation translation | SessionCompiler and its extension files |
| Shared plan or app-context schema | StudioProtocol |
| Swift/Kotlin syntax and helper emission | TestCodeGenerator |

See the [pipeline contributor guide](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/codegen-pipeline.md)
and [app-owned test context](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/test-context.md)
for implementation details.
