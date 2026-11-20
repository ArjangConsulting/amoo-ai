# Recording to generated tests

Turn a flow or a recorded session into a reviewed plan and native test source.

## Overview

Live device interaction and offline source generation are separate stages. A checked-in flow,
or a session Studio recorded, says what happened; SessionCompiler interprets that history; TestCodeGenerator emits native source from
the resulting plan. Compilation and emission do not require an LLM.

![Recorded calls become report.json, a compiled plan and replay flow, then native test source for the application's test target.](recording-pipeline.svg)

## Record evidence and intent

In a Studio session the tool executor records eligible tool calls as session actions, including
intent and outcome. Control-plane tools such as `device_boot` and `get_capabilities` do not become
application test steps. Diagnostics, failed probes,
and recovery attempts need interpretation rather than blind replay.

TestSession owns persistence to `report.json`. Offline readers and writers must use
`SessionReport.makeJSONEncoder()` and `makeJSONDecoder()` to preserve fractional timestamps;
losing that precision can change retry-collapse behavior.

## Compile the report

The CLI compiles a flow that passed (`amoo flow` runs the same file) or a saved session report
into a plan:

```bash
amoo generate plan --from-flow flows/login.amoo.json --out generated/
amoo generate plan --report report.json --out generated/
```

SessionCompiler maps recorded tool names onto the StudioProtocol operation vocabulary,
classifies the recorded intent, and produces warnings where translation is incomplete.
For example, the tool `assert_absent` maps to the plan's `assert_not_visible` operation.
The plan is the input to source generation; the flow artifact supports `amoo flow` replay.

## Supply application context and emit source

```bash
amoo generate test --plan generated/plan.json
```

StudioProtocol carries the plan and optional app-owned test context: base class, app factory,
launch behavior, imports, helper bindings, and identifier expressions. Supply that context when
your test target needs its own conventions. Generation does not infer arbitrary app helpers.

TestCodeGenerator emits XCUITest, Espresso, or Compose Espresso source. AmooTools does not depend
on TestCodeGenerator; the CLI composes the offline generation workflow. Review plan warnings and
resolve unsupported steps before treating the result as a regression test. The generated file
still needs to be integrated, compiled, and run in the application's test target.

## Find the right place to change behavior

| Change | Start here |
| --- | --- |
| Which calls are recorded and how intent is captured | AmooTools tool executor and recording extensions |
| Report encoding or storage | TestSession |
| Retry collapse, selector interpretation, and operation translation | SessionCompiler and its extension files |
| Shared plan or app-context schema | StudioProtocol |
| Swift/Kotlin syntax and helper emission | TestCodeGenerator |

See the [pipeline contributor guide](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/codegen-pipeline.md)
and [app-owned test context](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/test-context.md)
for implementation details.
