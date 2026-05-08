# Mobile Testing

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

## AI Provider Setup

The `ai_*` tools use deterministic fallback behavior by default. To enable a real model in the CLI or REPL, set an AI provider in your environment before launching `mobile-testing`.

Use local Ollama:

```bash
export MOBILE_TESTING_AI_PROVIDER=ollama
export MOBILE_TESTING_AI_OLLAMA_MODEL=qwen3.6:latest
mobile-testing
```

Optional Ollama overrides:

```bash
export MOBILE_TESTING_AI_OLLAMA_BASE_URL=http://localhost:11434
export MOBILE_TESTING_AI_OLLAMA_MODEL=qwen3.6:latest
```

Notes:

- If `MOBILE_TESTING_AI_PROVIDER=ollama` is set and no model is provided, the default is `qwen3.6:latest`.
- If you only set `MOBILE_TESTING_AI_OLLAMA_MODEL` or `MOBILE_TESTING_AI_OLLAMA_BASE_URL`, the CLI infers the Ollama provider automatically.
- Set `MOBILE_TESTING_AI_PROVIDER=local` to force the deterministic local provider.
- Leave `MOBILE_TESTING_AI_PROVIDER` unset, or set it to `none`, to keep AI tools in fallback mode.

Verify AI setup:

```bash
mobile-testing ai status
```

For Ollama, this checks both server reachability and whether the configured model is installed.

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
