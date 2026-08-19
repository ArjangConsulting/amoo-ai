# Amoo Studio architecture

Amoo Studio lives in the standalone
[`maniramezan/amoo-studio`](https://github.com/maniramezan/amoo-studio) repository. It is a pure
Compose Multiplatform desktop client and does not implement device control,
MCP tools, sessions, or model-provider logic. The application launches the Swift `amoo` executable
as a supervised child process and renders its structured state.

## Process boundary

The desktop application starts `amoo studio serve`. Communication uses JSON-RPC 2.0 over
Content-Length-framed standard input and output. Standard output is reserved for protocol frames;
diagnostics belong on standard error. Protocol changes are additive within a protocol version and
are negotiated through `system.handshake`.

The initial methods are:

| Method | Result |
| --- | --- |
| `system.handshake` | Product version, protocol version, and capability identifiers |
| `system.health` | Current service status |
| `devices.list` | Running and available simulators, emulators, and devices |
| `devices.start` | Boot a selected simulator or emulator |
| `apps.buildInstallRun` | Build, install, and launch an app |
| `apps.reinstallRun` | Reinstall the last artifact without rebuilding |
| `apps.resetData` | Remove app-local data after explicit approval |

Build and lifecycle behavior belongs to Amoo. iOS builds run through Amoo's
ShipItSwifty-backed process layer; Android builds use the project Gradle wrapper. Studio sends paths
and selections but never invokes Xcode, Gradle, `simctl`, `adb`, or emulator tools itself.

## Reusable process library

`process-rpc-kotlin` is the product-neutral extraction of the process boundary first implemented by
moqserver Studio. It owns Content-Length framing, JSON-RPC request correlation, subprocess
lifecycle and stderr draining, bundled binary discovery, and observable connection state.

It is published under the MIT license at `https://github.com/maniramezan/process-rpc-kotlin` and
consumed as the versioned `com.github.maniramezan:process-rpc-kotlin:0.1.0` dependency. Both Amoo
Studio and moqserver Studio can therefore use the same release without source checkouts.

## Distribution

Compose Desktop packages the matching released Swift executable as an OS/architecture-specific
resource. During development, set `AMOO_BINARY` to a local Amoo build. Studio always invokes the
resolved absolute path; installing a PATH link is optional and is not required for the GUI.
