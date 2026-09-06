# How Amoo works

Follow a request from a local AI client to a device, and see which module owns each part.

## Overview

Amoo runs orchestration on the host and UI automation inside a companion runner on the device.
Both platforms share test intent and wire contracts. Runtime capabilities determine whether a
particular operation is supported by the selected platform and device configuration.

![Requests pass through MCPServer and platform drivers, then use either host tooling or a gRPC companion.](runtime-overview.svg)

The arrows show runtime flow, not a complete import graph. `Package.swift` defines the actual
Swift dependency edges. CLI commands can call drivers directly; they do not all pass through MCP.

## Module responsibilities

| Module | Owns | Works with |
| --- | --- | --- |
| AmooCore | Shared action protocols, selectors, geometry, capabilities, observations, and errors | Common vocabulary for drivers and host services |
| IOSDriver / AndroidDriver | Platform implementations and routing to the right execution path | CompanionProtocol and ProcessRunner |
| CompanionProtocol | Host-side companion client and gRPC connection | AmooCore types and generated Protos messages |
| Protos | Shared protobuf service and message definitions | Generated Swift and Kotlin wire code |
| ProcessRunner | External process execution and host tooling adapters | simctl, devicectl, adb, and build tooling |
| MCPServer | AI-facing stdio tools, dispatch, observations, and session recording | Drivers, TestSession, SessionCompiler, audit and WebView services |
| GRPCService | Host-side service adapter exposing driver operations | Drivers, shared contracts, and AuditEngine |
| CommandContract | Shared command descriptions and contracts | CLI and tool-facing contract consumers |
| TestSession | Session models, lifecycle, history, and report persistence | MCP execution and offline report consumers |
| SessionCompiler | Deterministic conversion of recorded actions into plans and replay flows | TestSession and StudioProtocol |
| StudioProtocol | Plan, operation, context, warning, and export models | SessionCompiler and TestCodeGenerator |
| TestCodeGenerator | Native test source emitters and helper binding | StudioProtocol plans and explicit app context |
| AuditEngine | Deterministic rules evaluated against explicit evidence | Host orchestration provides evidence and consumes findings |
| WebInspector | Inspectable WebView support | Configured host inspection services |
| OllamaClient | Local model client | CLI features that request local inference |
| CLI | Setup, device commands, MCP server startup, and offline generation | Composes the library modules for command-line use |

The external AI client supplies reasoning when driving MCP tools. Running MCP does not require
routing every action through Ollama. Likewise, the host's GRPCService adapter and the companion's
gRPC server are separate roles: CompanionProtocol is the client that talks to the device.

## Walk through a tap

1. A local AI client sends a `tap_element` tool call with a session ID and a semantic selector.
2. MCPServer resolves the session and routes the request through its device operation queue.
3. The platform driver delegates UI interaction to its CompanionProtocol client.
4. The client sends a protobuf request over gRPC to the companion runner.
5. The iOS companion uses XCUITest; the Android companion uses UIAutomator. The companion
   resolves the target and performs the interaction. Ambiguous direct tap or text matches fail.
6. The result returns to the host. Eligible calls and their outcomes enter session history.
7. The caller observes the new state and checks an explicit postcondition before continuing.

A screen observation derives its context, element list, and change token from one scoped hierarchy
RPC. The token is not a frozen snapshot handle: the app can change between observation and action.
Stable accessibility identifiers and explicit assertions make that boundary easier to manage.

## Host and device ownership

Booting, installing, launching, and forwarding ports belong to host tooling. Taps, text input,
gestures, and hierarchy access belong to the companion. Capture routing can vary by platform and
operation. Physical iOS devices use an explicit USB tunnel; Android uses adb forwarding.

The companions run as test runners alongside the app under test: an XCUITest runner on iOS and
an instrumentation runner on Android. They are built separately with Xcode and Gradle, so a
successful Swift package build does not validate either companion app.

## Concurrency and persistence

MCP bounds in-flight request tasks and serializes complete response writes. Device queues serialize
operations for a device while allowing independent device keys to progress concurrently. Device
leases are process-local; use one server per device and dedicated hardware runners.

TestSession persists reports atomically and redacts known secrets. Pending history is periodically
flushed, and shutdown drains writes. Reports are rewritten in batches rather than appended to a
journal. Disk artifacts have no automatic deletion policy; plan retention for long-running runners.

## Device evidence placeholder

![Placeholder for three future fixture screenshots: observe the initial screen, perform an action, and verify the final state.](device-evidence-placeholder.svg)

This illustration reserves space for real fixture screenshots; it is not a capture of Amoo or
proof of a passing test. Replace it with anonymized iOS and Android captures showing the same
observe, act, and verify flow. Keep the selector and assertion explanation alongside the images.

## Continue reading

- <doc:RecordingToGeneratedTests>
- [Current runtime architecture](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/current-architecture.md)
- [Platform support and validation boundaries](https://github.com/arjangconsulting/amoo-ai/blob/main/docs/support-matrix.md)
