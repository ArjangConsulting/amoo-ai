# Prerequisites

Amoo depends on these external tools. Only `protoc` is needed for every build; the rest are
scoped to a platform or target type.

| Dependency | Install | Required for |
| --- | --- | --- |
| Xcode + Command Line Tools | App Store / developer.apple.com | Anything iOS |
| `protoc` | `brew install protobuf` | **All builds** — the gRPC Swift protobuf plugin |
| `xcodegen` | `brew install xcodegen` | Regenerating the iOS companion project |
| **`libimobiledevice`** | **`brew install libimobiledevice`** | **Physical iOS devices** — supplies `iproxy`, the USB tunnel to the companion. Not needed for simulators. |
| JDK 17–21 | `brew install --cask temurin@21` | Android companion. AGP 8.7 does not run on anything newer. The build resolves an installed JDK in this range on its own, so `JAVA_HOME` rarely needs setting. |
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
[Physical iOS Devices](physical-ios-devices.md) for why `libimobiledevice` is required.

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
