# Telemetry (OpenTelemetry)

amoo records **OpenTelemetry traces** for every CLI command, MCP request, tool call, companion RPC
and subprocess. The data is standard OTLP, so you can analyze it locally with `amoo usage report`
or send it to any OpenTelemetry backend (Jaeger, Honeycomb, Grafana Tempo, Datadog, the
Collector, …) next to your AI client's own telemetry.

## Where the data goes

| Sink | Default | Configure with |
| --- | --- | --- |
| Local OTLP/JSON file | **on**: `~/Library/Application Support/Amoo/sessions/telemetry/traces-YYYY-MM-DD.jsonl` (UTC day, `0600`, 14-day retention) | `AMOO_TELEMETRY_DIR=<dir>`, `AMOO_TELEMETRY_LOCAL=0` to turn off |
| OTLP exporter | off | `OTEL_TRACES_EXPORTER=otlp` and/or `OTEL_EXPORTER_OTLP_ENDPOINT` |
| Console (stderr) | off | `OTEL_TRACES_EXPORTER=console` |

The local file is the OpenTelemetry "OTLP File" format: one `ExportTraceServiceRequest` per line,
in OTLP/JSON (hex trace/span ids, integer enums). The Collector's `otlpjsonfile` receiver can
import it. The `AMOO_SESSIONS_DIR` override moves it together with session reports.

Two defaults differ from the OpenTelemetry SDK specification on purpose: remote export is off
until you configure it (developer machines rarely run a collector), and amoo always keeps the
local file so `amoo usage report` works without any setup.

### Standard environment variables

`OTEL_SDK_DISABLED`, `OTEL_SERVICE_NAME` (default `amoo`), `OTEL_RESOURCE_ATTRIBUTES`,
`OTEL_TRACES_EXPORTER` (`otlp`, `console`, `none`; comma-separated),
`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (used as-is),
`OTEL_EXPORTER_OTLP[_TRACES]_PROTOCOL` (`grpc`, `http/protobuf` — the default — or `http/json`),
`OTEL_EXPORTER_OTLP[_TRACES]_HEADERS`, `OTEL_EXPORTER_OTLP[_TRACES]_TIMEOUT` (ms),
`OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`.
Sampling is always-on: the local file is a usage ledger, so it is never sampled.

```bash
# Send amoo traces to a local collector over OTLP/gRPC
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
```

## Joining amoo with the AI client's traces

- **CLI from an agent's shell:** amoo reads W3C `TRACEPARENT`/`TRACESTATE` from the environment, so
  `amoo …` run by an agent whose tool spans export a `TRACEPARENT` (Claude Code does for Bash
  subprocesses) appears as a child of that tool call.
- **MCP:** a `traceparent` (and optional `tracestate`) string in a request's `params._meta` makes
  the `tools/call …` span a child of the client's trace.
- **Claude Code:** set `CLAUDE_CODE_ENABLE_TELEMETRY=1` with the same OTLP endpoint. Claude Code
  exports token usage (`claude_code.token.usage`, `api_request` events with input/output/cache
  tokens, attributed to subagents via `agent.name`) and `tool_result` events
  (`tool_name`, `duration_ms`, `tool_result_size_bytes`); amoo's spans give the device-side timing
  and payload sizes for the same calls. Without a collector, `amoo usage report --transcripts`
  reads token usage from Claude Code's local transcripts instead.

## What is recorded

Span names and attributes follow the OpenTelemetry MCP, GenAI (`execute_tool`), RPC and process
semantic conventions; amoo-specific measurements use `amoo.*`.

| Span | Kind | Key attributes |
| --- | --- | --- |
| `amoo <command>` (CLI root, not for `mcp serve`) | internal | `process.exit.code` |
| `tools/call <tool>`, `tools/list`, … (one per MCP request) | server | `mcp.method.name`, `gen_ai.tool.name`, `jsonrpc.request.id`, `mcp.protocol.version`, `amoo.client.name` |
| `execute_tool <tool>` (every surface: MCP, CLI, flows) | internal | `amoo.client` (`mcp`/`cli`/`flow`), `amoo.run.id`, `amoo.session.id`, `amoo.response.bytes`, `amoo.response.text_bytes`, `amoo.image.inline/bytes/width/height/scale`, `amoo.elements.observed`, `amoo.response.mode`, `amoo.call.repeated`, `error.type` |
| `device_queue.wait` | internal | time a call waited for its device |
| `amoo.CompanionService/<Method>` | client | `rpc.system=grpc`, `rpc.service`, `rpc.method`, `rpc.grpc.status_code`, `amoo.companion.server_ms` (companion's own handling time, from the `amoo-server-ms` trailer) |
| `hierarchy.read` | internal | tap-check reads |
| `exec <adb\|xcrun\|…>` | client | `process.executable.name`, `amoo.process.subcommand` (e.g. `shell input`), `process.exit.code` |
| `session_bootstrap`, `companion.ensure`, `app.install`, `app.launch`, `screen.ready` | internal | startup phases |

Never recorded: tool arguments, typed text, selector values, view-hierarchy contents, screenshots,
credentials. Subprocess spans keep only the executable and a lowercase subcommand. Error messages
are recorded on `exception` events, truncated.

The run ledger behind `get_run_telemetry` (`sessions/runs/<run_id>/`) is unchanged; it carries
cross-process counters for a run, including calls that never finished.

## Instrumenting code

Libraries use the standard [swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing)
API and never depend on the exporter:

```swift
import Tracing

try await withSpan("hierarchy.read") { span in
    span.attributes[TelemetryAttribute.observedElements] = nodes.count
    return try await driver.getViewHierarchy(appID: appID)
}
```

The `amoo` executable bootstraps `AmooTracer` once in `Sources/CLI/main.swift`
(`AmooTelemetry.bootstrap`) and flushes before exit. Tests run with the default no-op tracer;
`AmooTelemetry.makeTracer(exporters:resource:)` builds an isolated tracer for assertions.
Keep span names low-cardinality (no ids or values in names) and put attribute keys in
`TelemetryAttribute` (`Sources/AmooTelemetry/SemanticConventions.swift`).
