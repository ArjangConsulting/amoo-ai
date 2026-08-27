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
| Android CLI 1.0+ | [Android CLI](https://developer.android.com/tools/agents/android-cli) | **Recommended for Android inspection** — structured layouts and visual targeting. Amoo falls back to its companion when unavailable. |

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

## Android inspection backend

Production Android commands use Android CLI for unscoped hierarchy and element inspection, with
automatic fallback to Amoo's companion. Override the strategy when diagnosing behavior:

```bash
AMOO_ANDROID_INSPECTION_MODE=companion amoo device --platform android get_view_hierarchy
AMOO_ANDROID_INSPECTION_MODE=android-cli amoo device --platform android get_view_hierarchy
AMOO_ANDROID_INSPECTION_MODE=compare amoo device --platform android get_view_hierarchy
```

`compare` keeps the companion result authoritative and writes element counts and identity overlap
to stderr when both inspectors can acquire the device. Android currently allows only one active
UI-automation owner: while Amoo's instrumentation is running, Android CLI 1.0 may return an empty
or truncated layout. For a reliable A/B measurement, collect the companion sample, stop its
instrumentation, then collect the Android CLI sample against the unchanged screen. Queries scoped
to a package or system process always use the companion because Android CLI's current `layout`
command has no package-scoping option.

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
