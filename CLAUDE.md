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
| **JDK 17–26** | `brew install --cask temurin@21` | Android companion. The range is the intersection of AGP 9.3 (needs 17+) and Gradle 9.5 (runs on 17–26; 27+ unsupported). A JDK outside it fails partway through the build with errors naming neither Java nor the JDK. `make companion-android-build` and `amoo companion` resolve a supported JDK themselves (`scripts/android-jdk.sh` / `Sources/CLI/AndroidJDK.swift`), so `JAVA_HOME` only needs setting if one is installed somewhere non-standard. `swift run amoo preflight --platform android` reports which JDK was picked. Do not commit a `gradle/gradle-daemon-jvm.properties` — it pins the daemon to one JDK and silently downloads it, overriding the resolution above. |

### Android build stack

The companion is on AGP 9.3 / Gradle 9.5 with **AGP's built-in Kotlin** — there is deliberately no
`org.jetbrains.kotlin.android` plugin, because AGP 9's new DSL is incompatible with it. Two
consequences worth knowing before editing `CompanionApps/Android/*.gradle.kts`:

- Kotlin options go in a top-level `kotlin { compilerOptions { … } }` block. The old
  `android { kotlinOptions { … } }` form is deprecated-as-error under Kotlin 2.4.
- `gradle.properties` carries only `android.useAndroidX=true`. The AGP 9 upgrade needs none of the
  `android.newDsl` / `android.builtInKotlin` / `android.r8.*` opt-out shims — if you find yourself
  adding one, prefer fixing the underlying incompatibility, since they all disappear in AGP 10.
- `protobuf-gradle-plugin` must be ≥ 0.10.0; earlier versions cast to the removed `BaseExtension`
  and fail under the new DSL.
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
