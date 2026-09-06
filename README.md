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

Homebrew installs a prebuilt CLI and the companion projects. No amoo source checkout is needed.

## Quick Start (Homebrew)

For iOS, use macOS 15+ with Xcode and an installed simulator runtime:

```bash
brew install protobuf xcodegen
amoo preflight --platform ios
amoo mcp serve
```

For physical iOS devices, also install `libimobiledevice`. For Android, install a supported
JDK (17–26) and Android SDK, then run:

```bash
brew install --cask temurin@21
amoo preflight --platform android
amoo mcp serve --platform android
```

To let an AI drive a managed session, register amoo with your client. The Homebrew package
includes an installer you can run from any project:

```bash
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh"
```

It detects Claude Code, Claude Desktop, Codex, Cursor, and Windsurf, asks before writing,
and registers amoo in your user configuration for use across projects. For manual Claude Code
setup (also works with older packages without the installer):

```bash
claude mcp add --scope user amoo -- "$(brew --prefix amoo)/bin/amoo" mcp serve --platform ios
```

Then call `start_session` with `platform` and `app_id`, keeping the returned `session_id` on every
device call. See the [MCP guide](docs/mcp-server.md) for per-client config snippets, installer
options, and smaller tool profiles, and [prerequisites](docs/prerequisites.md) for platform tooling.

## Build from Source (Contributors)

From an amoo checkout, use Swift 6.2 or newer (see `Package.swift`) and install `protoc`:

```bash
brew install protobuf
swift build -c release
swift run amoo preflight --platform ios
make test
make lint
```

The user guides use `amoo` for the installed CLI. When developing from this checkout, substitute
`swift run amoo` or the absolute path to `.build/release/amoo`.

To register your local release build across projects:

```bash
scripts/install-mcp.sh --bin "$PWD/.build/release/amoo"
```

Repository end-to-end checks require a checkout and the platform tooling:

```bash
scripts/run-e2e-ios.sh
scripts/run-e2e-android.sh
```

## Documentation

- [Support and qualification](docs/support-matrix.md) — platform boundaries, CI and hardware qualification
- [Current architecture](docs/current-architecture.md) — runtime ownership and data flow

- [Prerequisites](docs/prerequisites.md) — external tooling, install steps, `make` targets
- [Physical iOS Devices](docs/physical-ios-devices.md) — `iproxy`, pairing, provisioning, current constraints
- [MCP For Local AI](docs/mcp-server.md) — running the MCP server, client config, reusable test flows
- [Amoo Studio](https://github.com/maniramezan/amoo-studio) — Compose desktop client
- [Studio protocol](docs/studio.md) — Swift service and GUI integration boundary
- [iOS E2E Runbook](docs/e2e-ios.md) — full workflow and troubleshooting
- [Command Contract Guide](docs/command-contract.md) — contributor checklist for coverage
- [API Documentation (DocC)](docs/documentation.md) — generating and browsing the DocC site
- [Homebrew release checklist](docs/homebrew.md) — tap setup and release checklist (maintainer-only)
- [Product/spec context](Instruction.md)
- [System design and module boundaries](Architecture.md)

Generated API reference is published from `main` to
[GitHub Pages](https://arjangconsulting.github.io/amoo-ai/).
