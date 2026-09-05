# MCP For Local AI

Amoo exposes AI-facing automation through MCP, implemented in Swift over the standard `stdio` transport.
The CLI does not configure or run an AI provider; local AI clients provide the reasoning and call Amoo tools.

## Prerequisites

Use `start_session` for managed sessions. It resolves the device, prepares the companion,
installs an optional `build_path`, and launches the target app. A companion does not need to be
running before the MCP server starts. Pass the returned `session_id` on subsequent calls.

For legacy calls without `session_id`, prepare the default companion yourself. Its host endpoint
is `127.0.0.1:22087` for iOS or `127.0.0.1:22088` for Android. Physical devices need USB forwarding.
Both companions bind IPv4 loopback. Remote network exposure is not a supported deployment mode;
there is no remote authentication/TLS layer. See [prerequisites](prerequisites.md).

## Start the server manually

```bash
swift run amoo mcp serve
```

By default this targets the iOS companion on port `22087`. For Android or custom ports:

```bash
swift run amoo mcp serve --platform android --port 22088
```

The server speaks JSON-RPC over `stdio` and exits cleanly when the client closes
stdin. It supports both stateless MCP `2026-07-28` requests and the legacy
`initialize` flow used by MCP `2025-11-25` clients.

## Connecting an MCP client

Add an entry to your MCP client's configuration. For Claude Desktop
(`~/Library/Application Support/Claude/claude_desktop_config.json`) and Cursor
(`~/.cursor/mcp.json`), the shape is the same:

```json
{
  "mcpServers": {
    "amoo": {
      "command": "swift",
      "args": [
        "run",
        "--package-path", "/absolute/path/to/amoo",
        "amoo", "mcp", "serve",
        "--platform", "ios"
      ]
    }
  }
}
```

For a faster startup, build once and point the client at the binary:

```bash
swift build -c release
```

```json
{
  "mcpServers": {
    "amoo": {
      "command": "/absolute/path/to/amoo/.build/release/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

## Inspect the server during development

```bash
npx @modelcontextprotocol/inspector swift run amoo mcp serve
```

Useful assistant-facing tools include:

- `describe_screen`
- `suggest_test_actions`
- `find_element_by_description`
- `analyze_ai_testability`

Use `analyze_ai_testability` to understand what developers can improve for better AI-driven testing: labels, identifiers, duplicate controls, hidden enabled elements, and missing primary actions.

## Reusable test flows

Keep deterministic smoke tests in a checked-in `*.amoo.json` file and run the whole sequence over
one companion connection:

```bash
amoo flow Examples/sign-in.amoo.json
```

Each step names a normal device/MCP tool. Exact `${ENV_NAME}` argument values are resolved from the
process environment so credentials do not enter source control. The runner stops at the first
failed action or assertion and prints the verified result for every completed step. See
[`Examples/sign-in.amoo.json`](../Examples/sign-in.amoo.json) for the format.

## Generating tests from a recorded session

The canonical workflow is `start_session` → drive the app → `end_session` → inspect `plan.json` →
`amoo generate test`. `end_session` **already** compiles the recorded history and writes
`plan.json` + `flow.json`; `compile_session_to_plan` is an optional preview you can call earlier,
while the session is still open, and it does not change the plan `end_session` writes. `amoo
generate test --plan` turns that plan into a standalone XCUITest / Espresso file.

amoo's own lifecycle calls (`start_session`, `end_session`, `compile_session_to_plan`,
`get_session_report`, …) are never recorded as app-under-test steps, so a complete app-interaction
recording generates without `--allow-incomplete` and with no trailing `XCTFail` — not even when an
explicit `compile_session_to_plan` preceded `end_session`.

To make the generated file fit a host test target — its base class, launch/assertion helpers, and
identifier catalog — pass an **app-owned test context**. Agents can supply it at session or compile
time (`start_session` / `compile_session_to_plan` accept `context_path` or `context_json`), and it
is persisted with the session so an `end_session` recompile keeps it. See
[`docs/test-context.md`](test-context.md) for the schema.

Offline, recompile a recorded `report.json` without re-running the server:

```bash
amoo generate plan --report report.json --context test-context.json --out out/
amoo generate test --plan out/plan.json
```

## Efficient and reliable clients

Set `AMOO_TOOL_PROFILE=drive`, `record`, or `audit` in the MCP process environment to advertise a
smaller task-specific catalog; `all` preserves the full catalog. Tool names and contracts remain
stable. Load `skills/driving-amoo/SKILL.md` first and its recording/coordinate references only when
needed. Contributor skills are not required to operate the device.

`describe_screen` derives context, actionable elements, and `screen_token` from a single hierarchy
observation. Tokens detect changes in labels, values, geometry, visibility, and tree order within
companion hierarchy limits. They are change hints, not durable selectors or proof of readiness.
Use explicit assertions as postconditions. Mutations reject ambiguous matches; refine with IDs
and `parent_id`. A timeout can occur after a device action started: inspect before retrying.

`find_elements`, `list_apps`, `list_sessions`, and `get_session_report` default to 50 results;
use `limit` and `next_offset` while `has_more` is true. Offsets query live state, so keep the screen
stable while paging and restart if it changes. Hierarchy output defaults to 200 nodes with an
explicit truncation marker. Truncated output cannot establish absence. Screenshots can be saved
without returning image tokens: pass `output` and `return_image=false`. Use `scale` to reduce
image dimensions. Reusable deterministic action sequences can use `amoo flow` to avoid a model
round trip per action.

Requests execute independently across devices and serialize per device within one server process.
Cancellation notifications propagate to outstanding request tasks. RPC deadlines and bounded input
frames prevent indefinite client work; device-side cancellation may finish later. Production
session bootstrap also rejects simultaneous leases of the same device within that process.

Reports flush after ten pending actions or five seconds of idle time, and at orderly shutdown.
An abrupt crash can lose the pending batch. `get_session_report` and `end_session` expose
`recording_health`: saved, pending, failed, unknown (no observed write), or disabled. A device action
can succeed while persistence fails; check this field before claiming the recording is durable. Known entered secrets and sensitive launch metadata
are redacted across recorded arguments, results, and observed selectors. `record_value=fixture`
explicitly preserves non-sensitive sample text for generation. Redacted values require runtime
bindings before complete test export. Screenshots can still contain sensitive pixels: choose
appropriate fixture data. Do not put secrets in test names or app-owned context files.

Audit results describe the inspected screen and include per-rule evidence coverage. No findings
is not a whole-app security certification; deep-link validation requires scenario evidence.

For a short known sequence, `run_steps` accepts an active `session_id` and an array of up to 20
`{"tool":"…","arguments":{…}}` objects. Actions and assertions execute in order under the same
device queue, stop at the first failure, and each attempted step is recorded once. Nested batches,
lifecycle calls and per-step session overrides are rejected before execution. Per-step timeouts
are capped at 10 seconds and gesture durations at 3 seconds. Completed actions are not rolled back.
Use normal discovery calls to decide the sequence first; batch responses contain compact summaries.
