# Repository and device initialization

`amoo init` prepares controlled simulators/emulators, reusing `env up` for device selection and runtime startup,
free-port choice and companion lifecycle. **No app build is required for setup.** It never asks for
an artifact path or scans Xcode DerivedData. Explicit `--app` input optionally installs an existing
artifact. Init does not build the product or provide a recording transport (see [Recording](#recording)).

## Guided (a person, in a terminal)

```sh
amoo init
```

It asks only for what you did not pass as flags, defaulting from what it can see:

1. **Platform** — iOS simulator or Android emulator.
2. **Framework** — native, React Native, Flutter or Kotlin Multiplatform guidance.
3. **Devices** — use ↑/↓ to move, Space to toggle devices, and Enter to continue.
   No devices are selected by default; select at least one before continuing. Press `a` to select or
   clear all. Redirected input uses `1,3`, `1-2`, or `all`. Devices reserved by other sessions are hidden.
4. **Where the manifest is written**. Device reservations use the label `amoo-init`; pass
   `--owner <label>` to customize it.
5. **AI clients** — offers to set up the amoo subagents and skills (see below).

When `--app` is explicitly supplied, it also asks for the app ID if omitted, defaulting from the
iOS app's `Info.plist`. When an app ID is supplied or collected, it asks whether to launch the app.
Without an app, setup skips installation and launch. Saved artifact paths are never selected
automatically.

Then it validates, prints the plan with the **equivalent non-interactive command**, asks
about AI clients, saving the setup locations in `AGENTS.md` and `Set up N device(s) now?`,
runs, and prints the next commands. EOF at any prompt cancels without touching a device.

## Headless (agents, CI)

`--json`, `--non-interactive`, or no terminal means **no prompts**. `--platform` and `--device`
(repeatable) are required. `--app-id` is also required when passing `--app` or `--launch`. Every
missing input is reported at once, along with available devices:

```sh
amoo init --platform ios --device PHONE_UDID --device TABLET_UDID --json
# Optionally install an explicitly supplied artifact during setup:
amoo init --platform ios --app /absolute/path/Jot.app --app-id com.example.jot \
  --device PHONE_UDID --device TABLET_UDID --launch --owner agent \
  --out /tmp/jot-environments.json --json
amoo init --platform ios --app ... --app-id ... --device ... --dry-run --json   # validate only
amoo init device --manifest /tmp/jot-environments.json --device PHONE_UDID --json current_app
amoo init device --manifest /tmp/jot-environments.json --device TABLET_UDID \
  device_launch_app app_id=com.example.jot --arg -UITest --arg fast
amoo init down --manifest /tmp/jot-environments.json --json
```

Android uses the same interface with running emulator serials and an optional absolute APK path.

## Validation, runtimes and partial failure

Starting setup reserves each selected device exclusively for amoo and starts the companion helper
app. Other amoo sessions cannot reserve the same device and interfere with your tests. The final
confirmation asks whether to start this setup now; reservation is a required part of setup.
The devices stay reserved after `init` exits. Run `amoo init down` when finished to stop the
companions and free the devices for another session.

Before anything is controlled, init checks that each device is an available simulator/emulator. If an
artifact is supplied, it also checks that the app exists with the right extension and that its own
bundle id matches `--app-id`. An artifact problem stops the run (it would doom every device).
A problem with one device — unknown, or controlled by
another session — is recorded and reported as that device's failed result while the others proceed;
if *every* device is unusable nothing starts. `env up` re-checks each runtime atomically, so init never
bypasses another session's runtime. Setup is sequential so companion builds serialize and port
allocation sees earlier runtimes. Physical devices are unsupported, as in `env up`. When an artifact
is supplied, its digest is computed once and shared with every `env up`.

## Output

Version-1 JSON: `ok`, `results[]`, optional `error`. Each result uses the env schema: `device`
(id/name/os), `runtime_id`, `platform`, `port`, `companion_pid`, `log`, `app`
(id/path/sha256/installed/launched), version/commit and `error`. Exit 1 means at least one device
failed; successes stay controlled until `init down`. `--out` rewrites the file **after every device**, so
an interrupted run still records the runtimes it started. The file is created `0600` (atomically) and holds
runtime ids: keep it private. Runtime TTL and ownership checks still apply; neither `init device` nor
`init down` forces another session's runtime.

## Remembered locations (`AGENTS.md`)

With consent (`--save` headless, a prompt in a terminal, `--no-save` to skip), init records the
platform, **manifest directory**, and any explicitly supplied **app artifact** and **app id** in a
managed block of `./AGENTS.md` (`--agents-file` to choose another). Without an app, the block is:

```markdown
<!-- amoo:init:start -->
## amoo init
- Platform: `ios`
- Manifests: `.` (device connection credentials; never commit `.amoo.json`)
<!-- amoo:init:end -->
```

Only text between the markers is rewritten. Device ids and runtime ids are never saved. The block
records setup locations for agents; saved app artifacts are not automatically installed.
Guided setup defaults to `.amoo.json` in the current project. Both platforms share this file.
If the manifest already exists, guided setup asks for confirmation before collecting setup inputs.
Declining or pressing Enter cancels without changing the file or touching devices. Selecting a
different existing manifest also requires confirmation before setup.
Repeated setup preserves existing reservation details for other devices. Successful `init down`
clears the file after releasing its reservations. Explicit `--out` paths are still supported.

## Recording

CLI runtimes cannot be adopted by MCP sessions. Run `init down`, then MCP `start_session` per device
with `device_hint`, `app_id` and the app's `build_path`; only `end_session` exports the report/plan.

## AI client setup (skills and subagents)

The same picker is available on its own as `amoo agent install` and as the last question of `amoo init`
(skip with `--no-skills`):

1. **Which AI clients?** Claude Code, Cursor, Codex, GitHub Copilot, Gemini CLI, OpenCode. Clients
   whose config directory exists under `~` (for example `~/.claude`) are marked *detected* and
   preselected; with none detected, all are preselected. Choose several with `1,3`, `1-2` or `all`.
2. **Where?** This repository (commit the files for your team) or your home directory (every project).
   Passing `--target` or `--user` answers this.
3. The exact files are listed (`would install` / `unchanged` / `skipped (differs; use --force)`) and you
   confirm before anything is written. Existing files are never overwritten without `--force`.

Passing `--client` (or `--json`, `--non-interactive`, or running without a terminal) skips every
question, so existing scripts keep their behaviour. Headless `amoo init --client claude,codex`
installs into the current repository after the devices are ready; headless init without `--client`
installs nothing. `--json` and skills cannot be combined in `init` (one JSON document per call): run
`amoo agent install --json` separately.

## Related

`amoo init repo …` is an alias for `amoo agent install …`.
The documented `device_launch_app --arg` is accepted and covered by parser tests. The Homebrew 0.2.1
crash is written up in [homebrew-0.2.1-crash.md](homebrew-0.2.1-crash.md).

The interactive platform picker offers **iOS**, **Android**, and **Both**. Both prepares
simulators and emulators without requiring app artifacts, validates the devices before setup, and
writes one shared connection file. The managed AGENTS.md block remembers locations for both platforms,
and later single-platform runs preserve the other platform’s locations.
The framework picker provides testing guidance for native apps, React Native, Flutter,
and Kotlin Multiplatform. React Native debug builds may require Metro to be started separately.
Terminal prompts use icons and color; `NO_COLOR` or `TERM=dumb` disables color.

With saved repository setup (`--save` or the guided save choice), init also discovers Swift UI-test and Kotlin/Java instrumentation
harness evidence into `amoo.md` alongside `AGENTS.md`. It does not generate tests or alter targets.
Existing profile sections and reviewed bindings are preserved; newly discovered platform sections are appended. Review uncertain target, catalog,
launch, and helper conventions before export; see [repository test context](test-context.md).
Recording and export consume its fenced context automatically from the repository working directory.

Guided setup defaults device connection files to `.amoo.json` in the current project. These
contain reservation tokens used to access and release devices, and are private local state;
init adds `/.amoo.json` to the project’s `.gitignore` so Git does not include them. `--out` can override
the location. AI-client installation during init is repository-local. Commit `amoo.md` and the
managed `AGENTS.md` guidance after reviewing the discovered conventions; do not commit connection files.

## What init captures for recording and export

`--save` (or the guided save choice) writes `amoo.md` from what the repository already says, so a
later recording does not depend on an agent re-deriving it. Besides the harness bindings (base
class, id catalog, waits, timeouts) it records:

| Captured | Where | Why it matters later |
| --- | --- | --- |
| **Launch configuration** — the language, locale and text-size flags (`-AppleLanguages`, `-AppleLocale`, `-UIPreferredContentSizeCategoryName`, `-AppleTextDirection`) the existing UI tests launch with, found in `launchArguments = […]`, `+= […]`, `.append(…)` and `launchEnvironment[…] =` sites | *Launch configuration (observed)* in `amoo.md`, with `file:line`; the flags every literal occurrence agrees on are seeded into the bindings' `launchArguments` | Label selectors and selected-state labels depend on them. `start_session` applies the seeded flags when the caller passes no `launch_args`, reports `launch_config_source`, and the plan's `requirements` replays them in `setUp`. |
| Flags that disagree or are computed (`[Self.sizeFlag, size]`) and environment switches (`OS_ACTIVITY_MODE`) | Listed, **never seeded** | Scenario and CI switches are the caller's to pass. |
| **Concurrency** — `SWIFT_VERSION`, `SWIFT_STRICT_CONCURRENCY`, `SWIFT_DEFAULT_ACTOR_ISOLATION` (Xcode project or `Package.swift`) and whether the harness base class is `@MainActor` | *Concurrency* in `amoo.md` | Generated tests are always `@MainActor`; for a base class that is not isolated the setup/teardown use the async `setUp()` / `tearDown()` hooks. This shows which case you are in. |
| **App identifiers** — `PRODUCT_BUNDLE_IDENTIFIER` of non-test targets | *App identifiers* in `amoo.md` | The `app_id` for `start_session`. |

Discovery reads checked-in sources and project files only (never build output), seeds a flag only
when the evidence is unambiguous, and leaves everything else as reviewable evidence. Review the
seeded `launchArguments` before relying on them; edit the `amoo-context` block to change them.

## Profile and JSON behavior

The framework choice is retained in the managed AGENTS.md block. Headless callers can supply
`--framework native|react-native|flutter|kmp`; dry-run JSON and its equivalent command include it.
This is project guidance, not permission to start Metro, build an app, or install a saved artifact.

CLI generation and MCP recording share the `amoo.md` profile loader. Discovery walks upward from
the process working directory and selects the nearest profile, respecting its target platform.
For another repository, explicitly pass `--context /repo/amoo.md` to generation or
`context_path=/repo/amoo.md` to MCP `start_session`. Explicit context overrides discovery;
`generate test` retains context already embedded in a plan. Markdown profiles support LF and CRLF.
Discovery inspects Swift UI tests and Kotlin/Java instrumentation sources under androidTest and
androidInstrumentedTest, excluding build outputs and dependencies. Android evidence includes framework,
base-class, rule, launch, helper, identifier and timeout declarations. A unique no-argument base without
lifecycle/rule conflicts can be bound automatically; uncertain bindings remain for review.
Mixed repositories get separate amoo-context blocks tagged targetPlatform ios/android. CLI and MCP
select the matching block, including explicit profile paths, and reject ambiguous or mismatched contexts.

Usage errors and manifest-read failures honor `--json` with a single version-1 error document.
If saving repository guidance fails, setup returns nonzero and JSON retains the started runtimes
alongside the save error. A requested manifest is checked for writability before starting runtimes; if a later
write fails, setup stops acquiring further devices and returns the credentials needed for cleanup.

See [Device runtimes](device-runtimes.md) for lifecycle states, device access coordination and saved-state migration.
