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
swift test
make lint
make format
```

Run only the protocol tests:

```bash
swift test --filter CompanionProtocolTests
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
