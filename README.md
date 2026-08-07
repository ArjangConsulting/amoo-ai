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

## Prerequisites

Amoo depends on these external tools. Only `protoc` is needed for every build; the rest are
scoped to a platform or target type.

| Dependency | Install | Required for |
| --- | --- | --- |
| Xcode + Command Line Tools | App Store / developer.apple.com | Anything iOS |
| `protoc` | `brew install protobuf` | **All builds** — the gRPC Swift protobuf plugin |
| `xcodegen` | `brew install xcodegen` | Regenerating the iOS companion project |
| **`libimobiledevice`** | **`brew install libimobiledevice`** | **Physical iOS devices** — supplies `iproxy`, the USB tunnel to the companion. Not needed for simulators. |
| JDK 21 | `brew install --cask temurin@21` | Android companion. Newer JDKs (26) fail with a `jlink` error. |
| Android SDK + platform-tools | Android Studio | Anything Android |

Install everything for iOS work, including physical-device support:

```bash
brew install protobuf xcodegen libimobiledevice
```

Then verify:

```bash
swift run amoo preflight --platform ios
```

Device-only tooling (`ios.devicectl`, `ios.iproxy`) reports `WARN` rather than `FAIL`, so a
simulator-only setup still passes preflight. See
[Physical iOS Devices](#physical-ios-devices) for why `libimobiledevice` is required.

## Common Commands

From the repo root:

```bash
make test
make lint
make format
```

The Make targets route through `scripts/with-protoc.sh` to locate `protoc`. If you invoke
`swift build` / `swift test` directly instead, export it once in your shell:

```bash
export PROTOC_PATH="$(command -v protoc)"
```

## Physical iOS Devices

Simulators need no extra tooling. Driving a **physical** iOS device additionally requires
the `iproxy` binary:

```bash
brew install libimobiledevice
```

`iproxy` itself ships in the `libusbmuxd` formula, which `libimobiledevice` pulls in as a
required dependency and links onto your `PATH` — so the command above is all you need. If
you want only the tunnel and none of the `idevice*` utilities, `brew install libusbmuxd` is
a smaller equivalent. Confirm with `which iproxy`.

`iproxy` forwards a port on your Mac to a port on the USB-connected device. It is needed
because a simulator shares `localhost` with the host — so the companion is directly
reachable — while a real device does not. Android solves this with the built-in
`adb forward`; Apple ships no equivalent, as `xcrun devicectl` has no port-forwarding
command at all. Without `iproxy` there is no route from the host to the companion running
on the device.

Amoo starts and stops the tunnel itself; you only need the binary installed. Check your
setup with:

```bash
swift run amoo preflight --platform ios
```

`ios.devicectl` and `ios.iproxy` report `WARN` rather than `FAIL` when missing, since
simulator-only workflows never use them.

Two further requirements for real hardware:

- The device must be paired and trusted — verify with `xcrun devicectl list devices`.
- The XCUITest companion runner must be signed with a provisioning profile valid for that
  device. Simulators skip code signing entirely.

One capability is simulator-only: `setPermission`. `simctl privacy` can grant and revoke
TCC permissions, and `devicectl` has no counterpart, so on a device Amoo fails that call
explicitly rather than pretending it worked. Grant permissions manually in Settings.

## MCP For Local AI

Amoo exposes AI-facing automation through MCP, implemented in Swift over the standard `stdio` transport.
The CLI does not configure or run an AI provider; local AI clients provide the reasoning and call Amoo tools.

### Prerequisites

The MCP server is a thin wrapper around the platform driver — it requires a running
companion app on the loopback gRPC port:

- iOS companion on `127.0.0.1:22087` (default)
- Android companion on `127.0.0.1:22088` (default)

Boot a companion before sending tool calls — for example with
`scripts/run-e2e-ios.sh --skip-build` or `scripts/run-e2e-android.sh --skip-build`,
or by running the companion app from `CompanionApps/`.

### Start the server manually

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

### Connecting an MCP client

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
        "--package-path", "/absolute/path/to/mobile-testing",
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
      "command": "/absolute/path/to/mobile-testing/.build/release/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

### Inspect the server during development

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
