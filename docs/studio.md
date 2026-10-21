# Amoo Studio architecture

Amoo Studio lives in the standalone
[`maniramezan/amoo-studio`](https://github.com/maniramezan/amoo-studio) repository. It is a pure
Compose Multiplatform desktop client and does not implement device control,
MCP tools, sessions, or model-provider logic. The application launches the Swift `amoo` executable
as a supervised child process and renders its structured state.

## Process boundary

The desktop application starts `amoo studio serve`. Communication uses JSON-RPC 2.0 over
Content-Length-framed standard input and output. Standard output is reserved for protocol frames;
diagnostics belong on standard error. Protocol changes are additive within a protocol version and
are negotiated through `system.handshake`.

`StudioService` reads frames on a dedicated thread and handles each request concurrently, writing
responses and notifications through one serialized writer. Responses can therefore arrive out of
order; Studio correlates them by `id`. `StudioDeviceLocks` keeps work on one device in arrival order
(`devices.start`, `apps.*`, `repl.execute` with a selected device, and `tests.run`/`tests.start`),
while different devices proceed in parallel. Services push JSON-RPC notifications through
`StudioNotificationCenter`. A notification from Studio (no `id`) runs without a response. Handler
failures keep the request `id` and use `-32602` for invalid params and `-32603` otherwise.

| Capability | Meaning |
| --- | --- |
| `rpc.concurrent` | Requests are handled concurrently as described above |
| `rpc.notifications` | Amoo may push notifications on the protocol stream |
| `tests.progress` | Asynchronous test runs push `tests.progress` with the `tests.status` shape on every change |
| `device.stream` | `amoo device stream` is available for live device views; its `started` event carries `schema` |
| `tools.catalog` | `tools.catalog` returns the console and plan vocabulary built from the MCP registry |
| `repl.complete` | `repl.complete` completes a console line, including elements on a connected device's screen |
| `repl.validate` | `repl.validate` returns diagnostics for a console line |
| `agent.runs` | `agent.start`, `agent.events`, `agent.approve`, `agent.continue`, and `agent.cancel` run provider-backed agents, pushing `agent.event` |
| `tests.generate` | `tests.generate` returns generated source with a source map, or the problem that stopped generation |
| `repl.recording` | `repl.startRecording` and `repl.stopRecording` record console commands into a session |
| `repl.structuredResults` | `repl.execute` runs any console tool and returns `isError`, `tool`, `structuredContent`, and `artifacts` |

The catalog capabilities are advertised only when `amoo studio serve` is assembled with a
`StudioToolCatalogProviding`, which the CLI builds from `MCPServer().toolDefinitions()`.

- **Tool schemas.** Each `tools.catalog` entry carries:
  - `name`, `title`, `description` and `category`;
  - `readOnly` and `destructive`, the MCP annotations;
  - `replSupported`, which is false for session and companion lifecycle tools, since Studio runs those itself;
  - `planTool`, the plan vocabulary name (`assert_absent` records as `assert_not_visible`);
  - typed `arguments` with `values` and `valuesAreExhaustive`. `session_id` is hidden because the
    console routes by the selected device.
- **Value hints.** `ToolCatalogMetadata` in MCPServer keeps the value hints and annotations in one
  table. Exhaustive value sets are published in MCP schemas as `enum`, and open sets as `examples`.
- **The console grammar.** `StudioReplGrammar` is pure and shared by completion, validation and
  execution. Built-in commands match by words. Tool calls take `name=value` words, with quotes
  anywhere in a word. A bare value fills the next missing required argument.
- **Positions.** Positions are UTF-16 offsets, as Studio's editor reports them.
- **Completion.** `repl.complete` takes `{line, cursor, selectedDeviceId?, platform?}` and returns
  `{replaceStart, replaceEnd, items, isIncomplete}`. Element values come from `find_elements` on a
  device whose companion is already connected; completion never starts a companion. They are
  cached for 3 seconds and dropped after any command that is not read-only.
- **Validation.** `repl.validate` takes `{line}` and returns `{diagnostics: [{start, end, severity, message}]}`.
- **Destructive commands.** A console tool marked destructive is refused with a pointer to the
  approved workflow, replacing the old word-based check that refused harmless text such as
  `type_text text="delete me"`.
- **Screenshots.** With `captureScreenshot: true`, `repl.execute` takes a settled screenshot
  (`settle_timeout_ms` 1500) after any tool that is not read-only, whether it succeeded or failed.
  It returns `screenshot: {path, widthPixels, heightPixels, widthPoints, heightPoints, scale}`. A
  failed capture is logged and leaves the command's result unchanged.
- **Gesture points.** `gesturePoint: {x, y}`, in points, reports where a tap landed. Coordinate taps
  take it from their arguments, and `tap_element` from the `tap_point` field its structured result
  now carries.
- **Platform.** `repl.execute` accepts an optional `platform` for the selected device. Older Studio
  builds omit it, and the active test's platform is used instead.
- **Plan vocabulary.** Plan names the MCP executor does not implement run as the tools the session
  compiler records them from:

  | Plan tool | Runs as |
  | --- | --- |
  | `assert_not_visible` | `assert_absent` |
  | `wait_for_element` | `assert_visible` |
  | `assert_text` | `assert_visible`; the expected text constrains the element's `label`, or becomes `contains_text` without a selector |

Methods, with the capability that enables each one when it differs from the method name:

| Method | Result |
| --- | --- |
| `system.handshake` | Product version, protocol version, and capability identifiers |
| `system.health` | Current service status (capability `health`) |
| `mcp.status` | MCP readiness, transport, and launch arguments |
| `devices.list` | Running and available simulators, emulators, and devices |
| `devices.start` | Boot a selected simulator or emulator |
| `devices.create` | Create a simulator or emulator through the typed process layer |
| `apps.buildInstallRun` | Build, install, and launch an app |
| `apps.reinstallRun` | Reinstall the last artifact without rebuilding |
| `apps.resetData` | Remove app-local data after explicit approval |
| `chat.send` | Send provider-neutral conversation state through the configured AI provider |
| `providers.check` | Verify a provider profile can connect |
| `repl.execute` | Execute a console command; with `repl.structuredResults`, any console tool with structured output and screenshots |
| `repl.complete` / `repl.validate` | Complete or validate a console line |
| `repl.startRecording` / `repl.stopRecording` | Record console commands on a device into a session, then end it and write its plan |
| `tools.catalog` | The console and plan vocabulary |
| `tests.run` | Validate and execute a compiled `.amootest` plan and wait for it |
| `tests.start` / `tests.status` / `tests.cancel` | Run a plan asynchronously; with `tests.progress`, status is also pushed |
| `tests.export` | Generate native test source (save-only flow) |
| `tests.generate` | Generate native test source with a source map, or the problem that stopped it |
| `agent.start` / `agent.events` / `agent.approve` / `agent.continue` / `agent.cancel` | Provider-backed agent runs (capability `agent.runs`) |
| `reports.list` | Return persisted Studio test reports and artifacts |

Notifications pushed by Amoo are `tests.progress` and `agent.event`.

Provider secrets come from the profile's inline `apiKey`, which Studio sends only when Amoo advertises `providers.apiKey`, or else from the named environment variable; neither is persisted or logged. Studio test
execution requires a compiled plan; authored intent without executable operations fails explicitly.
Reports are owned and persisted by Amoo. REPL commands reject destructive operations so those actions
continue to require an explicit approval event in Studio.

Build and lifecycle behavior belongs to Amoo. Both iOS and Android builds and device operations run
through Amoo's ShipItSwifty-backed process layer (`GradleKit`, `Adb`, and the Apple command
families). Android builds still select the project's Gradle wrapper through `GradleKit`. Studio sends paths
and selections but never invokes Xcode, Gradle, `simctl`, `adb`, or emulator tools itself.

## Reusable process library

`process-rpc-kotlin` is the product-neutral extraction of the process boundary first implemented by
moqserver Studio. It owns Content-Length framing, JSON-RPC request correlation, subprocess
lifecycle and stderr draining, bundled binary discovery, and observable connection state.

It is published under the MIT license at `https://github.com/maniramezan/process-rpc-kotlin` and
consumed as the versioned `com.github.maniramezan:process-rpc-kotlin:0.1.0` dependency. Both Amoo
Studio and moqserver Studio can therefore use the same release without source checkouts.

## Distribution

Compose Desktop packages the matching stopped Swift executable as an OS/architecture-specific
resource. During development, set `AMOO_BINARY` to a local Amoo build. Studio always invokes the
resolved absolute path; installing a PATH link is optional and is not required for the GUI.

## Agent runs

`agent.start` takes `{provider, messages, activeTest, deviceId, platform, appId, buildPath?,
launchArguments?, maxSteps?}` and returns `{runId}`. `StudioAgentRun` then runs in this order:

1. **Start a session.** It calls `start_session` on the session-backed `DriverToolExecutor` that
   `amoo mcp serve` uses (`CLIStudioAgentSession`), so the run records a real session.
2. **Loop over model turns.** It streams turns from the provider through `StudioAgentModels`, which
   covers OpenAI and OpenAI-compatible Chat Completions, Anthropic Messages, and Ollama
   `/api/chat`, all with native tool calling. Each tool call runs in the session under the
   device's lock and goes back to the model as a tool result.
3. **End the session.** `end_session` writes `plan.json` and `flow.json`, even when the run is
   cancelled.

How the loop behaves:

- **Tools.** The model is offered the console's tool catalog. Session and companion lifecycle
  tools are excluded.
- **Approvals.** A destructive tool pauses the run (`approvalRequired`) until `agent.approve`
  answers. A declined call is reported to the model and never runs.
- **Screenshots.** After every tool that is not read-only, the run captures a settled screenshot
  with `DriverToolExecutor.observeScreenshot`. It is saved under the session's `studio-screens`
  directory and is not recorded, so it never becomes a step in a generated test.
- **Redaction.** Typed text in `type_text`, `set_text`, and `fill_field` arguments appears in
  events only as its length.
- **Steering.** `agent.continue {runId, message}` adds a user message before the next turn.
- **Cancelling.** `agent.cancel` stops the run, resolves pending approvals as declined, and still
  ends the session.
- **One run per device.** Starting a second run on a device that already has a running one is
  refused.

### Events

Each event is pushed as an `agent.event` notification with `{runId, seq, kind, …}`. The kinds are
`sessionStarted`, `assistantDelta`, `assistantMessage`, `toolCall`, `toolResult` (with
`screenshot` and `gesturePoint`), `approvalRequired`, `approvalResolved`, `usage`, `error`, and
`finished` (with `state`, `planPath`, and `flowPath`).

`seq` increases by one per event, so a client that sees a gap replays with `agent.events {runId,
after}`. That returns `{state, events, nextSeq}` from the last 5,000 events. Events are also
appended to `studio-agent-events.jsonl` in the session directory.

`assistantDelta` events stream model text. They repeat the `seq` of the next numbered event, and
they are neither kept nor logged, because `assistantMessage` carries the full text.

## Test generation

`tests.generate` and `amoo generate test` share one pipeline, `StudioTestGenerationPipeline` in
TestCodeGenerator:

1. Apply app context: an explicit `contextPath`, or `amoo.md` discovered upward from `projectPath`.
   Beside an `.xcodeproj` or `.xcworkspace`, discovery starts from the folder that contains it.
2. Validate the context, rename the test, and bind context helpers.
3. Refuse incomplete plans unless `allowIncomplete` is set, and always refuse redacted values.
4. Emit the source.

`tests.export` runs the same pipeline when the generator is configured.

### Request

`tests.generate` takes:

- `sessionId`: the source is the session's `plan.json`. A session that ended without one is
  compiled from its report.
- `test`: an authored test, used instead of a session.
- `uiToolkit`, `testName`, `allowIncomplete`, `projectPath`, `contextPath`.

### Result

The result is `{generated?, problem?, test}`:

- **`generated`:** `{fileName, source, language, sourceMap}`. Each source-map entry is
  `{operationIndex, operationId, startLine, endLine}`, with lines 1-based and inclusive.
- **`problem`:** `{kind: incomplete | redacted | noEmitter, message, warnings}`. It is returned
  instead of a protocol error, so Studio can show the reasons and offer `allowIncomplete`.
- **`test`:** the plan exactly as generated, including all of its warnings.

### Source maps

Emitters implement `generateMapped`. It re-renders each operation's deterministic statements, then
`StudioSourceMapper` aligns them with the finished source, comparing lines without surrounding
whitespace. Post-processing only reindents lines, inserts `XCTFail` lines, or drops a wait that
repeats the line before it, so the alignment is exact and the generated code is unchanged.

A compiled session names each operation `step-<n>`, where `n` is the index of the recorded action.
Agent `toolResult` events carry that `actionIndex`, so a step in generated code links back to its
screenshot. For this reason the agent is not offered `run_steps`, which records several actions per
call.

## Console recording

Console commands are not recorded by default: they run through `CLIStudioToolExecutor`, which has no
session. Recording routes them through a session so they can be generated into a test.

1. **Start.** `repl.startRecording {deviceId, platform, appId, buildPath?, launchArguments?,
   testName?}` starts a session on the device, which launches the app fresh, and returns
   `{sessionId, deviceId, actionCount}`. Starting again while recording returns the current
   recording.
2. **Record.** While a device records, `repl.execute` runs console tools in that session through
   `CLIStudioSessions`, the same session-backed executor agent runs use. Each result carries the
   `actionIndex` it recorded and the `sessionId`, and a compiled plan names that step
   `step-<actionIndex>`.
   - Built-in commands and test runs are not recorded.
   - Screenshots come from `DriverToolExecutor.observeScreenshot`, and completion's elements from
     `observeElements`. Neither records anything, so neither becomes a step.
3. **Stop.** `repl.stopRecording {deviceId}` ends the session, which writes `plan.json` and
   `flow.json`, and returns their paths with the action count. `tests.generate {sessionId}` then
   generates the test.

**One session per device.** `StudioDeviceSessions` lets a device record one session at a time, so a
console recording and an agent run refuse each other's device with `StudioSessionError.deviceBusy`.

**Shutdown.** When Studio's input closes, `amoo studio serve` cancels agent runs and stops
recordings, so their sessions are written.

