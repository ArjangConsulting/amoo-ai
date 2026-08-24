# amoo

AI-driven mobile testing framework providing drivers and libraries for automating tests on iOS and Android simulators/emulators and real devices. Local AI integration is exposed through MCP via `amoo mcp serve`.

## Project Status

Greenfield project — no code yet. See `Instruction.md` for the full vision.

## Tech Stack

- **Primary language**: Swift (other languages where appropriate)
- **Communication**: gRPC (language-agnostic, high-performance)
- **AI integration**: MCP + Skills (hybrid approach), with external local AI clients using the MCP stdio server
- **Platforms**: iOS (simulators + devices), Android (emulators + devices)

## Architecture

- **Interface libs**: Shared protocol/interface definitions for cross-platform feature parity
- **Platform implementations**: iOS-specific and Android-specific drivers implementing the shared interfaces
- **Modular design**: Easy to extend with new platforms, actions, and AI integrations
- **gRPC services**: Bridge between drivers/libraries and AI tools

### Key Modules (Planned)

- Device drivers (scroll, tap, type, screenshot, video recording)
- App audit engine (issues, security, UX, test reliability)
- AI test generation
- CLI + REPL interface
- CI/CD integration

## Design Principles

- AI as first-class citizen in the testing process
- Feature parity between iOS and Android
- Mockable and testable — design for easy mocking and unit testing
- User-friendly errors with setup hints
- Apps identified by app ID or app name

## Build & Test

```bash
swift build
swift test
make lint          # swiftformat --lint + swiftlint --strict
make format
```

The companion apps are **not** covered by `swift build` — they build through Xcode and
Gradle, so verify them separately after changing anything under `CompanionApps/`:

```bash
make companion-ios-build       # xcodegen + xcodebuild build-for-testing
make companion-android-build   # gradle assembleDebug assembleAndroidTest
```

## External Dependencies

| Tool | Install | Needed for |
| --- | --- | --- |
| `protoc` | `brew install protobuf` | gRPC Swift protobuf build plugin (all builds) |
| **JDK 17–21** | `brew install --cask temurin@21` | Android companion. AGP 8.7 does not run on anything newer; a JDK 26 build fails with a `jlink` / `core-for-system-modules.jar` error, or a missing `com/android/aaptcompiler/ResourceCompiler` in `mergeDebugResources` — neither mentions the JDK. `make companion-android-build` and `amoo companion` resolve a supported JDK themselves (`scripts/android-jdk.sh` / `Sources/CLI/AndroidJDK.swift`), so `JAVA_HOME` only needs setting if one is installed somewhere non-standard. `swift run amoo preflight --platform android` reports which JDK was picked. |
| `iproxy` | `brew install libimobiledevice` | **Physical iOS devices only.** USB tunnel to the companion — `devicectl` has no port forwarding, unlike Android's `adb forward`. Simulators don't need it. The binary actually ships in `libusbmuxd`, pulled in and linked as a dependency of `libimobiledevice`. |
| `kotlinc` | `brew install kotlin` | **Optional, test-only.** Real-compiles generated Espresso code in `GeneratedCodeCompileTests` (`Tests/TestCodeGeneratorTests/`). Missing → those two tests `XCTSkip` rather than fail. The Kotlin check also needs a resolved Espresso/JUnit/Hamcrest classpath, produced by `Tooling/espresso-classpath/resolve.sh` (invokes `gradle`, needs network on first run, then caches to `$TMPDIR/amoo-espresso-classpath`). The Swift-side check (`swiftc -typecheck` against the iOS Simulator SDK) needs no extra install — Xcode alone is enough. |

`swift run amoo preflight --platform ios` checks these; device-only tooling reports `WARN`
rather than `FAIL` so simulator-only setups still pass.

## Gotchas

- **Never run a formatter over vendored SPM checkouts.** They live under gitignored
  `build/SourcePackages/checkouts/`, so reformatting them is invisible to git but silently
  corrupts the dependency — this previously stripped `: Sendable` conformances out of
  `grpc-swift-2` and broke the iOS companion build with errors that appeared to originate
  in the dependency. `.swiftformat` excludes these paths; keep it that way. Recover with
  `git checkout -- .` inside the affected checkout.
- `swiftformat` is not idempotent here — run it twice per file to reach a stable result.

## Conventions

- Follow Swift modern APIs (`async/await`, `@Observable`, Swift Testing)
- gRPC proto files define the shared interface contract
- Keep platform-specific code isolated behind shared protocols
- Document public APIs
- Log operations using structured logging (see global CLAUDE.md for Logger patterns)
