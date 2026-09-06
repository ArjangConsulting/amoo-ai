# Prerequisites

Install the prebuilt CLI with `brew install arjangconsulting/tap/amoo`. The examples below use
that installed `amoo` command and work outside the amoo repository. Platform tooling is still
needed to build and run companions; Homebrew supplies their projects with the CLI.

For source development, use `swift run amoo` from the checkout instead. `protoc` is needed
for Swift builds, including the iOS companion; other tools depend on the platform or target.

| Dependency | Install | Required for |
| --- | --- | --- |
| Xcode + Command Line Tools | App Store / developer.apple.com | Anything iOS |
| `protoc` | `brew install protobuf` | **All builds** — the gRPC Swift protobuf plugin |
| `xcodegen` | `brew install xcodegen` | Regenerating the iOS companion project |
| **`libimobiledevice`** | **`brew install libimobiledevice`** | **Physical iOS devices** — supplies `iproxy`, the USB tunnel to the companion. Not needed for simulators. |
| JDK 17–26 | `brew install --cask temurin@21` | Android companion. The project uses AGP 9.3 / Gradle 9.5. The build resolves an installed JDK in this range on its own, so `JAVA_HOME` rarely needs setting. |
| Android SDK + platform-tools | Android Studio | Anything Android |
| Android CLI 1.0+ | [Android CLI](https://developer.android.com/tools/agents/android-cli) | Optional diagnostic inspector for structured-layout comparison. Amoo's companion is the production default. |

Install everything for iOS work, including physical-device support:

```bash
brew install protobuf xcodegen libimobiledevice
```

Then verify:

```bash
amoo preflight --platform ios
```

Device-only tooling (`ios.devicectl`, `ios.iproxy`) reports `WARN` rather than `FAIL`, so a
simulator-only setup still passes preflight. See
[Physical iOS Devices](physical-ios-devices.md) for why `libimobiledevice` is required.

## Android inspection backend

Production Android commands use Amoo's companion for hierarchy and element inspection. It is the
authoritative source because it preserves package scope, parent semantics, Compose clickable
ancestors, and the complete accessibility tree while the instrumentation session owns Android's
UI-automation connection. Override the strategy when diagnosing behavior:

```bash
AMOO_ANDROID_INSPECTION_MODE=companion amoo device --platform android get_view_hierarchy
AMOO_ANDROID_INSPECTION_MODE=android-cli amoo device --platform android get_view_hierarchy
AMOO_ANDROID_INSPECTION_MODE=compare amoo device --platform android get_view_hierarchy
```

`compare` keeps the companion result authoritative and writes element counts and identity overlap
plus companion-only / Android-CLI-only identity counts to stderr when both inspectors can acquire
the device. Android currently allows only one active
UI-automation owner: while Amoo's instrumentation is running, Android CLI 1.0 may return an empty
or truncated layout. A non-empty Android CLI result is therefore not proof that the layout is
complete, which is why `automatic` is companion-first and uses Android CLI only if companion
inspection fails. For a reliable A/B measurement, collect the companion sample, stop its
instrumentation, then collect the Android CLI sample against the unchanged screen. Queries scoped
to a package or system process always use the companion because Android CLI's current `layout`
command has no package-scoping option.

## Contributor Commands

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
