# Mobile Testing Platform: Product and Technical Specification

## 1. Purpose

Build a Swift-first, AI-native, cross-platform mobile testing platform that automates iOS and Android apps across simulators/emulators and real devices.

The platform must be:

- reliable enough for CI
- usable from CLI and MCP clients
- extensible for future providers, platforms, and AI workflows
- designed for deterministic automation first, with AI augmentation where it adds value

## 2. Vision

Provide a single automation surface for mobile testing and auditing that works across:

- iOS + Android
- simulator/emulator + physical device
- deterministic tool execution + AI-assisted planning

The long-term goal is an ecosystem: drivers, protocol contracts, CLI/REPL, MCP server, and skill-based workflows that can be embedded in any agent stack.

## 3. Product Principles

1. Protocol-first architecture
- Public interfaces are stable, versioned, and mockable.
- Implementations can be swapped without breaking consumers.

2. Intent-level parity, not forced primitive parity
- Cross-platform APIs should represent user intent (for example: `goBack`, `openApp`, `tap`, `type`).
- Platform-specific limitations are exposed through capabilities, not hidden behind unstable shims.

3. Deterministic first, AI second
- Prefer accessibility tree and direct selectors for interaction and assertions.
- Use screenshots/vision fallback only when deterministic selectors are unavailable.

4. AI as first-class citizen
- AI should help generate, validate, repair, and explain test flows.
- AI must consume structured context, not only raw screenshots/XML dumps.

5. Operational realism
- Design for long-running sessions, flaky device states, retries, reconnects, and clean recovery.

6. Security and observability by default
- Every remote command path must be auditable and policy-controlled.

## 4. Scope and Boundaries

### In Scope

- Core Swift package(s): contracts, shared types, errors, orchestration abstractions
- iOS and Android drivers
- Companion communication contract (gRPC/Protobuf)
- CLI and REPL
- MCP server tools for AI clients
- App audits: quality, security heuristics, UX and testability suggestions
- Capture artifacts: screenshots and videos
- CI/CD support, docs, examples, and test fixtures

### Out of Scope (initially)

- Full no-code GUI product
- Fully autonomous "always-correct" AI agents
- Replacement for platform-native test frameworks (XCUITest/Espresso/UIAutomator); we orchestrate them
- Vendor-specific cloud device farm management as a hard dependency

## 5. Architecture Alignment (Authoritative)

This spec follows the structure in `Architecture.md` and clarifies important boundaries.

### 5.1 Responsibility Split

Host side responsibilities:

- device lifecycle (boot/shutdown/connect/disconnect)
- app lifecycle (install/uninstall/launch/terminate where platform tools are best source)
- orchestration, retries, sessions, logs, artifact management
- CLI, REPL, MCP tooling, policy enforcement

Companion side responsibilities:

- UI interactions on active app/session
- view hierarchy extraction and element queries
- screen context generation for AI
- platform bridge operations through XCUITest/UIAutomator/Espresso-compatible adapters

### 5.2 Capability Model (Future-Proofing Requirement)

Every driver/companion pair must expose runtime capabilities:

- required core capabilities (must exist on both iOS and Android)
- optional capabilities (feature flags)
- unsupported capabilities (explicit reason)

No API should silently degrade. If unsupported, return a typed error with remediation hints.

### 5.3 Contract Versioning

Use semantic versioning for:

- Swift public protocols
- gRPC/proto contracts
- MCP tool schemas

Compatibility guarantees:

- additive fields/actions are backward compatible
- removals/behavioral changes require major version increments
- each release publishes a migration note

## 6. Technology Decisions

- Primary language: Swift (core platform, drivers, CLI/REPL, MCP, gRPC host services)
- gRPC + Protobuf: mandatory for host-companion contracts
- Platform-native bridges:
- iOS: XCUITest-based companion bridge
- Android: UIAutomator/Espresso-compatible companion bridge
- MCP stdio server for local AI clients:
- Swift implementation
- provider-neutral tools; AI reasoning lives in the external MCP client

Where another language is chosen (for example Android instrumentation internals), it must be hidden behind stable cross-language contracts.

## 7. Competitive/Industry Learnings Applied

Based on current ecosystem patterns (Maestro, Mobile Next mobile-mcp, Appium):

- Cross-platform APIs are most durable when based on intent and accessibility-first interactions.
- Flakiness handling must be built in (auto-wait, retries, timeout semantics), not left to end users.
- Tooling should support both deterministic automation and AI workflows.
- Runtime extensibility (drivers/plugins/providers) is essential to avoid lock-in.

This project should combine those strengths while prioritizing Swift-first modularity and stronger protocol contracts.

## 8. MVP Requirements (Phase 1)

### 8.1 Core Automation

- iOS and Android drivers with a shared core action set:
- tap/double tap/long press
- swipe/scroll/drag
- type/set/clear text
- navigation intents (`back`, `home`, `openUrl`, `pressButton` where supported)
- app selection by app id/package id, with optional name resolution

### 8.2 Query and Context

- view hierarchy retrieval
- element lookup by structured selectors
- wait primitives with deterministic timeout behavior
- AI-ready screen context model (compact, semantic, token-efficient)

### 8.3 Artifacts and Diagnostics

- screenshot capture
- video recording
- structured logs/traces with correlation IDs
- actionable setup/runtime errors with remediation text

### 8.4 AI Integration

- MCP tools for core actions and queries
- skill-compatible command surfaces/workflows
- AI-assisted test case generation from app state + user intent
- external AI client support through MCP stdio
- embedded local-model support through the same tool executor for CLI and Studio clients

### 8.5 Audit Features

- app quality audit checks
- security heuristic audit checks
- UX/testability recommendations
- exportable audit report format (JSON + human-readable markdown)

### 8.6 Developer Experience

- CLI commands for device/app/session management and test execution
- REPL mode for live interactive control
- examples and templates
- CI-friendly non-interactive mode and deterministic exit codes

## 9. Post-MVP (Phase 2+)

- natural-language flow execution and repair loops
- parallel execution and worker orchestration
- integrations with major testing ecosystems
- Compose Multiplatform Studio for orchestration, reports, artifact inspection, and local-model chat
- advanced policy engine for enterprise controls

## 10. Non-Functional Requirements

### Reliability

- built-in retries and bounded waits
- explicit idempotency guidance per command
- session recovery and cleanup hooks

### Performance

- minimize command round-trips
- support batched query operations where safe
- avoid high-token payloads by default; provide compact context formats

### Testability

- all boundaries mockable via protocols
- unit tests for every protocol implementation
- integration tests per platform
- contract tests for proto compatibility
- lint/format gates in CI must pass for every pull request
- formatter: SwiftFormat
- linter: SwiftLint (strict mode)
- coverage gate: `AmooCore` line coverage >= 85%
- coverage gate: driver and protocol modules line coverage >= 75%
- coverage gate: repo-wide line coverage >= 80% before `v1.0.0`
- coverage gate: pull requests cannot reduce coverage by more than 1% without explicit approval in review

### Documentation

- API reference + architecture overview + quickstart
- troubleshooting guides for simulator/emulator/device setup
- migration notes for breaking changes

### Security

- transport security and authentication strategy for remote usage
- command authorization/policy layer
- sanitized logging (no accidental sensitive data leakage)

## 11. Roadmap and Milestones

### Milestone 0: Foundation

- finalize contracts, capability model, and error taxonomy
- lock module boundaries and package layout
- create golden test fixtures

Exit criteria:

- architecture decision records approved
- first compile of core modules

### Milestone 1: Platform Bring-up

- iOS + Android baseline drivers
- core action set + hierarchy/query support
- CLI alpha

Exit criteria:

- deterministic smoke tests pass on both platforms

### Milestone 2: AI + MCP

- MCP server with stable tools
- local AI client integration through MCP stdio
- AI-assisted flow generation and action suggestions

Exit criteria:

- end-to-end AI-driven flow demo on both platforms

### Milestone 3: Audit and Reporting

- quality/security/UX/testability audit packs
- structured report output
- screenshot/video and trace linking

Exit criteria:

- reproducible audit report generation in CI

### Milestone 4: Scale

- parallel execution framework
- provider expansion (cloud AI APIs)
- hardened observability and policy controls

Exit criteria:

- stable parallel runs and clear SLOs under load

## 12. Success Metrics

- action success rate by platform/device type
- flaky test reduction over time
- median command latency and end-to-end flow duration
- audit report usefulness (developer acceptance/fix rate)
- AI-assisted flow success without manual intervention
- onboarding time for new developers
- code coverage trend by module and branch (`main`, release branches)

## 13. Key Risks and Mitigations

1. False parity assumptions
- Mitigation: capability negotiation + explicit unsupported responses

2. Platform framework instability
- Mitigation: isolate via bridge layers and contract tests

3. AI nondeterminism
- Mitigation: deterministic execution layer, AI only for planning/suggestion unless explicitly approved

4. Operational drift across environments
- Mitigation: environment validators, preflight checks, and reproducible CI fixtures

## 14. Immediate Next Actions

1. Convert this spec into tracked issues (one milestone epic + sub-issues).
2. Add a capability matrix document (`required`, `optional`, `unsupported`) for iOS and Android.
3. Define v1 proto schema and compatibility policy.
4. Implement preflight environment checks in CLI.
5. Build MVP smoke tests on one iOS simulator and one Android emulator before adding breadth.
6. Add coverage tooling + CI gating and publish coverage dashboards/artifacts per run.
