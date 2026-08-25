# Amoo Mobile Testing

Swift-first mobile testing infrastructure for iOS and Android, with:

- protocol-based drivers
- gRPC companion communication
- CLI and MCP surfaces
- deterministic automation first, AI workflows second

## Repo Layout

- [Sources](Sources): Swift packages for drivers, protocol, server, CLI
- [CompanionApps](CompanionApps): iOS and Android companion apps
- [Tests](Tests): unit and integration tests
- [scripts](scripts): CI and local helper scripts

## Install

```bash
brew tap arjangconsulting/tap
brew install amoo
```

Or build from source (see Quick Start below).

## Quick Start

Install `protoc` (required for every build):

```bash
brew install protobuf xcodegen libimobiledevice
```

Verify your setup:

```bash
swift run amoo preflight --platform ios
```

Build and test:

```bash
make test
make lint
```

Run the iOS end-to-end flow against a booted simulator:

```bash
scripts/run-e2e-ios.sh --skip-build
```

See [docs/prerequisites.md](docs/prerequisites.md) for the full dependency table and rationale.

## Documentation

- [Prerequisites](docs/prerequisites.md) — external tooling, install steps, `make` targets
- [Physical iOS Devices](docs/physical-ios-devices.md) — `iproxy`, pairing, provisioning, current constraints
- [MCP For Local AI](docs/mcp-server.md) — running the MCP server, client config, reusable test flows
- [Amoo Studio](https://github.com/maniramezan/amoo-studio) — Compose desktop client
- [Studio protocol](docs/studio.md) — Swift service and GUI integration boundary
- [iOS E2E Runbook](docs/e2e-ios.md) — full workflow and troubleshooting
- [Command Contract Guide](docs/command-contract.md) — contributor checklist for coverage
- [API Documentation (DocC)](docs/documentation.md) — generating and browsing the DocC site
- [Homebrew install](docs/homebrew.md) — tap setup and release checklist (maintainer-only)
- [Product/spec context](Instruction.md)
- [System design and module boundaries](Architecture.md)

Generated API reference is published from `main` to
[GitHub Pages](https://arjangconsulting.github.io/amoo-ai/).
