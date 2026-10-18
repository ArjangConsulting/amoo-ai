# amoo

AI-driven mobile testing framework: drivers and libraries for automating tests on iOS and Android
simulators/emulators and real devices. Local AI integration is exposed through MCP via
`amoo mcp serve`. See `Instruction.md` for the original vision and `Architecture.md` for the
module map, protocol hierarchy, and companion-app design.

This file is the shared instruction set for any coding agent. Tool-specific notes live alongside
it (`CLAUDE.md` for Claude Code); everything here applies regardless of which agent is running.

## Tech Stack

- **Primary language**: Swift (Swift tools 6.2, macOS 15+). Other languages where appropriate.
- **Communication**: gRPC (language-agnostic) between host drivers and the on-device companions.
- **AI integration**: MCP stdio server + skills (`skills/`), for external local AI clients.
- **Platforms**: iOS (simulators + devices), Android (emulators + devices), at feature parity.

## Build & Test

```bash
swift build
swift test                 # XCTest, ~1500 case executions across ~15 bundles; a clean run is ~1–2 min
make lint                  # swiftformat --lint  +  swiftlint --strict   (both, they enforce different rules)
make format                # swiftformat, run twice (not idempotent here — see scripts/ci/format.sh)
make check                 # format + lint + test — the pre-commit gate
make release-local          # rebuild .build/release/amoo (what an MCP client pointed at a checkout runs); prints `amoo version`
```

Every code contribution must pass `make lint` before it is committed or submitted for review. Run
it **after the final code edit**, even when formatting already ran — SwiftFormat and SwiftLint
enforce different rules. Do not defer lint cleanup to CI or a release-prep pass.

The companion apps are **not** covered by `swift build` — they build through Xcode and Gradle, so
verify them separately after changing anything under `CompanionApps/`:

```bash
make companion-ios-build       # xcodegen + xcodebuild build-for-testing
make companion-android-build   # gradle assembleDebug assembleAndroidTest
```

### Verifying the Linux build locally

CI's `Build & Test (Linux)` job (`.github/workflows/ci.yml`) runs in the `swift:6.3-noble`
container. Reproduce it locally with Docker instead of guessing at platform gating — a
`#if canImport(Darwin)` / `#if os(Linux)` split that looks right can still leave a symbol
undefined or a test asserting on an empty result:

```bash
make verify-linux                    # build --product amoo + test (mirrors the CI job)
./scripts/verify-linux.sh build      # build only
./scripts/verify-linux.sh test       # test only (add --filter by editing, or use `shell`)
./scripts/verify-linux.sh shell      # interactive shell in the container
```

It builds into `.build-linux/` (gitignored) so the host `.build/` is left alone, and skips
`IntegrationTests` + `CLIQualityCoverageTests` exactly as CI does. Run it after any change to
platform-conditional code (`ProcessRunner`, anything with `#if os`/`canImport`) before pushing.

### Test conventions and mechanics

- Most tests are **XCTest** (`final class X: XCTestCase`); some existing targets use Swift Testing.
  Match the surrounding target and file instead of migrating unrelated tests.
- Logic is deliberately split across `Foo.swift` + `Foo+Feature.swift` extension files to satisfy
  the `file_length` lint rule (`SessionPlanCompiler` → `.swift` / `+Semantics` / `+Inspection` /
  `+Translation`; `DriverToolExecutor` → `ToolExecutor.swift` + `ToolExecutor+*.swift`; likewise
  `MCPServerTests+*`). **When hunting for behavior, grep the whole `Foo*` set, not just `Foo.swift`.**
- `swift test --filter` on a class defined via `extension MCPServerTests { … }` needs the fully
  qualified `BundleName.ClassName/testMethodName`, e.g.
  `swift test --filter 'MCPServerTests.MCPServerTests/testSessionTimeContextSurvivesEndSessionRecompile'`.
  The bare class name matches nothing.
- Scratch files and directories come from `TemporaryDirectory` in
  [SwiftTestCommons](https://github.com/maniramezan/SwiftTestCommons). In `CLITests`, use
  `makeScratchDirectory()` / `makeTemporaryDirectory()` (removed on teardown); elsewhere,
  `let scratch = try TemporaryDirectory(); defer { try? scratch.remove() }`. When the code under test
  must create a path itself, pass a child such as `scratch.url.appending(path: "store")`.
- Poll with `waitUntil(timeout:pollInterval:operation:matching:)` instead of
  `for … where … { Task.sleep }` loops; it uses a monotonic deadline and reports the last value.
- `.proto` files in `Protos/` are the shared companion-service contract. The host-side Swift is
  **generated and committed** in `Sources/Protos/Generated` — normal builds do not run the
  `GRPCProtobufGenerator` plugin, because it makes SwiftPM compile `protoc` from C++ source
  (3–6 min per clean build). After editing a `.proto`, run `make protos` and commit the result;
  `make protos-check` (CI's Linux job) fails on stale output. The plugin only runs under
  `AMOO_REGENERATE_PROTOS=1` (see `Package.swift`).

### Lint: recurring fixes

`swiftlint --strict` rejects patterns that come up often here:

| Rule | Fix |
| --- | --- |
| `blanket_disable_command` | A file-wide `// swiftlint:disable <rule>` needs a matching `// swiftlint:enable <rule>` at EOF. Test files with many inline fixtures use `// swiftlint:disable multiline_arguments` … `// swiftlint:enable multiline_arguments` bracketing the whole body (see `GenerateCommandTests.swift`). |
| `multiline_arguments` | A multi-line call must be all-on-one-line or strictly one-argument-per-line — no mixing. SwiftFormat will re-wrap into the mixed form, so bracket the file with the disable/enable pair instead. |
| `prefer_self_in_static_references` | Inside a type's own body, refer to it as `Self`, not by name. |
| `optional_data_string_conversion` | `String(bytes: data, encoding: .utf8)`, not `String(decoding: data, as: UTF8.self)`. |
| `cyclomatic_complexity` / `function_body_length` | For an inherently long linear switch (arg parsing, a tool dispatch), add `// swiftlint:disable:next <rule>` with a one-line reason rather than splitting it artificially. |
| `no_trailing_comment` (custom) | Never end a line of code with a comment. Put it on its own line above the code. This applies to Kotlin, Python and shell too, which lint does not check. |

SwiftFormat is not idempotent on this codebase — `make format` runs it twice; do the same if you
run `swiftformat` directly on specific files.

## `amoo init` (guided multi-device setup)

Code: `Sources/CLI/Init*.swift` — `InitCommand.swift` (manifest, `runInit`, `init down|device`),
`InitCommand+Run.swift` (flow: collect → validate → confirm → run), `InitWizard.swift` (flags, prompts,
plan), `InitDiscovery.swift` (devices, bundle id), `InitSavedLocations.swift` (the `AGENTS.md` block),
`AgentInstallWizard.swift` (guided `amoo agent install`, also the AI-client step of init). Prompts come
from SwiftyTerminal's `Prompting`/`Prompter` (see "Terminal UX" below). Tests: `Tests/CLITests/Init*Tests.swift` (`InitTestCase` holds the fakes). Docs: `docs/init.md`.
It reuses `runEnvUp`/`runEnvDown`; never duplicate lease, port or companion logic there.

- `amoo init` never asks for an app artifact path or scans for builds. Artifacts are optional and
  only used with explicit `--app`. `--json`/`--non-interactive`/no TTY never prompts and requires
  `--platform --device`; `--app-id` is also required with `--app` or `--launch`.
- The AI-client step (`amoo agent install` guided; `amoo init --client`/`--no-skills`) reuses
  `runAgentInstall`; with `--client`, `--json`, `--non-interactive` or no TTY it never prompts.
- It writes a managed `## amoo init` block (between `amoo:init` HTML-comment markers) with the
  platform, manifest directory and any explicitly supplied app artifact/id — **locations only,
  never device or lease ids**. Saved app paths are not automatically selected on later runs.

## Terminal UX (SwiftyTerminal)

Colors, prompts (text, secret, yes/no, single key, radio/checkbox menus), spinners, progress, step
lists, live command output, tables/alerts and the REPL line editor come from
[SwiftyTerminal](https://github.com/maniramezan/SwiftyTerminal) (`SwiftyTerminal`,
`SwiftyTerminalLineEditor`), shared with ShipIt. Add terminal UX there, not in `Sources/CLI`. It tracks
`branch: "main"` until `0.1.0`; while it is unpublished, resolve it from a local checkout with
`swift package config set-mirror --original https://github.com/maniramezan/SwiftyTerminal.git --mirror <path>`.

## Recording → plan → generated-test pipeline

The session-recording and code-generation path (MCP tool calls → `report.json` →
`compile_session_to_plan` → `plan.json` → `amoo generate test` → an XCUITest/Espresso file) is
mapped in **[`docs/codegen-pipeline.md`](docs/codegen-pipeline.md)** — read it before changing
`SessionPlanCompiler`, the emitters, `ToolExecutor` recording, or the MCP `initialize` instructions.
App-owned generated-test context (base class, helpers, id catalog) is in
[`docs/test-context.md`](docs/test-context.md).

Fidelity rules that span those stages (details in the pipeline doc): selector fields `id` /
`label` / `contains_text` are **all-must-match** constraints, with `parent_id` scoping applied first
(host-side, from the view hierarchy) and `index` / `first` last; an observation (`find_elements`
printing `selected`) never becomes an assertion — only `assert_selected` does; an explicit assertion
is never rewritten into a weaker one (emitters throw, warnings carry a `category`); and generated
XCUITest classes are `@MainActor`. `element_label` on a gesture is a constraint, so compiler-added
naming hints go in `name_hint`.

## Distributable plugin (`plugins/amoo`)

The user-facing subagents (`amoo`, `device-verifier`) and skills (`driving-amoo`,
`device-verifier`) live in `plugins/amoo/`, packaged for every client's marketplace: Claude and
Cursor (`.claude-plugin/` / `.cursor-plugin/`), Agent Plugins 1.0 (`plugin.json`, used by Copilot
and Codex), and Gemini (`gemini-extension.json`). The repo-root `.claude-plugin/`,
`.cursor-plugin/` and `.agents/plugins/` hold the marketplace catalogs. `agents/*.md` is the
canonical source and keeps only `name` and `description` in its frontmatter. `amoo agent install`
renders it for each client (`Sources/CLI/AgentRenderer.swift`), and `make plugin` regenerates the
committed `com.github.copilot/agents/*`. `AmooPluginTests` fails on stale or inconsistent files.

## External Dependencies

`amoo preflight --platform ios|android` checks these; device-only tooling reports `WARN`
rather than `FAIL`, so simulator-only setups still pass.

| Tool | Install | Needed for |
| --- | --- | --- |
| `protoc` | `brew install protobuf` | `make protos` (regenerating `Sources/Protos/Generated`) and the iOS companion's `generate-protos.sh`. **Not** needed for `swift build` / `swift test`. |
| **JDK 17–26** | `brew install --cask temurin@21` | Android companion. The range is the intersection of AGP 9.3 (17+) and Gradle 9.5 (17–26; 27+ unsupported). A JDK outside it fails partway through the build with errors naming neither Java nor the JDK. `make companion-android-build` and `amoo companion` resolve a supported JDK themselves (`scripts/android-jdk.sh` / `Sources/CLI/AndroidJDK.swift`); `JAVA_HOME` only needs setting for a non-standard install location. Do **not** commit `gradle/gradle-daemon-jvm.properties` — it pins and silently downloads one JDK, overriding that resolution. |
| `iproxy` | `brew install libimobiledevice` | **Physical iOS devices only.** USB tunnel to the companion (`devicectl` has no port forwarding, unlike `adb forward`). Ships in `libusbmuxd`, pulled in as a dependency of `libimobiledevice`. |
| `kotlinc` | `brew install kotlin` | **Optional, test-only.** Real-compiles generated Espresso code in `GeneratedCodeCompileTests`. Missing → those tests `XCTSkip`. Also needs a resolved Espresso/JUnit/Hamcrest classpath from `Tooling/espresso-classpath/resolve.sh` (runs `gradle`, network on first run, then caches to `$TMPDIR/amoo-espresso-classpath`). The Swift-side `swiftc -typecheck` check needs only Xcode. |

### Android build stack

AGP 9.3 / Gradle 9.5 with **AGP's built-in Kotlin** — deliberately no `org.jetbrains.kotlin.android`
plugin (AGP 9's new DSL is incompatible with it). Before editing `CompanionApps/Android/*.gradle.kts`:

- Kotlin options go in a top-level `kotlin { compilerOptions { … } }` block. The old
  `android { kotlinOptions { … } }` form is deprecated-as-error under Kotlin 2.4.
- `gradle.properties` carries only `android.useAndroidX=true`. The AGP 9 upgrade needs none of the
  `android.newDsl` / `android.builtInKotlin` / `android.r8.*` opt-out shims — fix the underlying
  incompatibility instead; they all disappear in AGP 10.
- `protobuf-gradle-plugin` must be ≥ 0.10.0; earlier versions cast to the removed `BaseExtension`
  and fail under the new DSL.

## Gotchas

- **Never run a formatter over vendored SPM checkouts.** They live under gitignored
  `build/SourcePackages/checkouts/`, so reformatting them is invisible to git but silently corrupts
  the dependency — this previously stripped `: Sendable` conformances out of `grpc-swift-2` and
  broke the iOS companion build with errors that appeared to originate in the dependency.
  `.swiftformat` excludes these paths; keep it that way. Recover with `git checkout -- .` inside the
  affected checkout.
- `report.json` date handling lives in **one** place — `SessionReport.makeJSONEncoder()` /
  `makeJSONDecoder()` (ISO-8601 *with* fractional seconds). Any offline reader/writer of a report
  must use them, or sub-second timestamp precision is lost and the retry-collapse heuristic
  silently changes its output.

## Conventions

- Follow Swift modern APIs (`async/await`, `@Observable`); **but** tests stay on XCTest.
- gRPC proto files define the shared companion interface contract.
- Keep platform-specific code isolated behind the shared protocols (`Architecture.md`).
- Document public APIs.
- Structured logging: `Logger.forType(subsystem:…, …Type.self)` from SwiftCommons; log before and
  after async operations and on every error with feature/action/state context; never log user data.

## Versioning

Bare SemVer, no `v` prefix, anywhere (tags, releases, version strings, SwiftPM pins). Trunk-based
until 1.0 — commit straight to `main`, no feature branches. Confirm any new convention (tag
notation, first version number, branch/commit naming) before creating it.
