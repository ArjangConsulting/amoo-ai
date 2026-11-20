# Command Contract Guide

This repo now treats public commands as a release contract.

## What Is Covered

- Device tools are declared in `Sources/AmooTools/Tools/*`.
- The shared command inventory lives in `Sources/CommandContract/CommandCoverageMatrix.swift`.
- Every public tool must have:
  - a coverage-matrix entry
  - a deterministic or AI classification
  - a release tier
  - a fixture screen
  - an expected assertion

## Naming Rules

- Assistant-facing tools use provider-neutral names.
- Tool names must not use the removed `ai_*` prefix.
- Current canonical assistant tools are:
  - `describe_screen`
  - `suggest_test_actions`
  - `analyze_ai_testability`
  - `find_element_by_description`
- Start a runtime with `amoo env up` and call a tool with `amoo device --runtime-id <id> <tool>`.

## Blocking vs Informational

- Blocking release coverage is deterministic command behavior on the repo-owned fixture apps.
- AI flows are informational by default and run in the smoke lane.
- Proto-only or unimplemented commands must stay hidden from the public tool catalog until they are supported end-to-end.

## Contributor Checklist

When adding a new public command:

1. Add the tool definition and executor routing.
2. Add a `CommandCoverageMatrix` entry.
3. Add or reuse a fixture screen/assertion path.
4. Add at least one regression or e2e assertion.
5. Check the public schema with `amoo capabilities --tool <tool>`.

## Entry Points

- iOS: `bash scripts/run-e2e-ios.sh`
- Android: `bash scripts/run-e2e-android.sh`
- Both: `bash scripts/run-e2e-all.sh`

## Adding a Device Tool

Touch four files plus tests:

1. **Declare the tool** in the appropriate group under `Sources/AmooTools/Tools/`
   (`DeviceTools`, `ActionTools`, `QueryTools`, `AuditTools`, or `AssistantTools`).
   Set `name`, optional `title`, `description`, `properties`/`required` for inputs,
   and an `outputSchema` for any tool that returns structured content.
2. Add a dispatch case in `Sources/AmooTools/ToolExecutor+Dispatch.swift`. Return
   `.success(prose, structuredContent: try Value(report))` when the tool has a declared output
   schema so callers can validate against it.
3. **Register the contract** in `Sources/CommandContract/CommandCoverageMatrix.swift`
   with the right `channel` (`.tool` for catalog tools, `.cli` for top-level `amoo …`
   commands), `kind`, `releaseTier`, fixture screen, and expected assertion.
4. **Update tests**:
   - Tool name and schema assertions in `Tests/AmooToolsTests/AmooToolsTests.swift`
     (`testToolNamesAreExposed`, `testToolDefinitionsHaveSchemas`).
   - Driver-level execution test in the same file, using `MockDriver` or
     `AuditMockDriver` depending on what the tool touches.
   - Use `scripts/ci/cli-smoke.py` for device-free checks of the packaged binary.

For assistant-facing tools, also add the prose formatter in
`Sources/AmooTools/AssistantReports.swift` alongside the matching `Codable` report
struct so structured content stays in sync with the declared `outputSchema`.
