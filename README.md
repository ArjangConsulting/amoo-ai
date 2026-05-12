# Amoo Mobile Testing

Swift-first mobile testing infrastructure for iOS and Android, with:

- protocol-based drivers
- gRPC companion communication
- CLI and MCP surfaces
- deterministic automation first, AI workflows second

The high-level design lives in [Instruction.md](Instruction.md) and [Architecture.md](Architecture.md). This README is the practical entry point.

## Repo Layout

- [Sources](Sources): Swift packages for drivers, protocol, server, CLI
- [CompanionApps](CompanionApps): iOS and Android companion apps
- [Tests](Tests): unit and integration tests
- [scripts](scripts): CI and local helper scripts

## Common Commands

From the repo root:

```bash
make test
make lint
make format
```

The gRPC Swift protobuf build plugin needs a `protoc` executable. Install it with
`brew install protobuf`, then either use the Make targets, which run through
`scripts/with-protoc.sh`, or export it once in your shell:

```bash
export PROTOC_PATH="$(command -v protoc)"
```

## MCP For Local AI

Amoo exposes AI-facing automation through MCP, implemented in Swift over the standard `stdio` transport.
The CLI does not configure or run an AI provider; local AI clients provide the reasoning and call Amoo tools.

Start the local MCP server:

```bash
swift run amoo mcp serve
```

By default this connects to the iOS companion on port `22087`. For Android or custom ports:

```bash
swift run amoo mcp serve --platform android --port 22088
```

Inspect the server during development:

```bash
npx @modelcontextprotocol/inspector swift run amoo mcp serve
```

Useful assistant-facing tools include:

- `describe_screen`
- `suggest_test_actions`
- `find_element_by_description`
- `analyze_ai_testability`

Use `analyze_ai_testability` to understand what developers can improve for better AI-driven testing: labels, identifiers, duplicate controls, hidden enabled elements, and missing primary actions.

Run only the protocol tests:

```bash
scripts/with-protoc.sh swift test --filter CompanionProtocolTests
```

Run the iOS companion end-to-end flow:

```bash
scripts/run-e2e-ios.sh --skip-build
```

Run the Android companion end-to-end flow:

```bash
scripts/run-e2e-android.sh --skip-build
```

Run both platform suites:

```bash
scripts/run-e2e-all.sh --skip-build
```

See the full iOS e2e runbook in [docs/e2e-ios.md](docs/e2e-ios.md).
See the command contract guide in [docs/command-contract.md](docs/command-contract.md).

## iOS E2E Quickstart

1. Boot an iOS simulator in Simulator.app.
2. Run:

```bash
scripts/run-e2e-ios.sh --skip-build
```

If you want a specific simulator:

```bash
scripts/run-e2e-ios.sh --skip-build --device "iPhone 17 Pro"
```

If multiple matching simulators exist, the script prompts you to choose one when running interactively.

## Current Constraint

The repo-root iOS e2e flow is simulator-only today.

Connected physical devices are detected and reported, but this flow still depends on:

- companion access over `127.0.0.1:22087`
- `simctl` for host-side iOS device actions

So physical-device fallback is not implemented yet for `scripts/run-e2e.sh`.

## More Detail

- iOS e2e workflow and troubleshooting: [docs/e2e-ios.md](docs/e2e-ios.md)
- Command contract coverage and contributor checklist: [docs/command-contract.md](docs/command-contract.md)
- Product/spec context: [Instruction.md](Instruction.md)
- System design and module boundaries: [Architecture.md](Architecture.md)
