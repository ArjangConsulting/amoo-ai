# Repository and device initialization

`amoo init` prepares leased simulators/emulators from **one prebuilt app**, reusing `env up` for
device selection, leasing, free-port choice, companion lifecycle, install and launch. It never
builds the app and is not a recording transport (see [Recording](#recording)).

## Guided (a person, in a terminal)

```sh
amoo init
```

It asks only for what you did not pass as flags, defaulting from what it can see:

1. **Platform** — iOS simulator or Android emulator.
2. **App** — built `.app`/`.apk` found under the current directory and Xcode DerivedData (newest
   first; UI-test runners and device builds excluded), or the location remembered in `AGENTS.md`.
3. **App ID** — read from the app's `Info.plist` (iOS); typed for Android.
4. **Devices** — pick several (`1,3`, `1-2`, `all`). Leased devices are hidden; booted ones default.
5. **Launch**, **owner label**, and **where the manifest is written**.
6. **AI clients** — offers to set up the amoo subagents and skills (see below).

Then it validates, prints the plan with the **equivalent non-interactive command**, asks
about AI clients, `Record the app and manifest locations in AGENTS.md?` and `Set up N device(s) now?`,
runs, and prints the next commands. EOF at any prompt cancels without touching a device.

## Headless (agents, CI)

`--json`, `--non-interactive`, or no terminal means **no prompts**. All of `--platform`, `--app`
(absolute), `--app-id` and `--device` (repeatable) are required; every missing one is reported at once,
with the built apps and unleased devices found, so one retry is enough:

```sh
amoo init --platform ios --app /absolute/path/Jot.app --app-id com.example.jot \
  --device PHONE_UDID --device TABLET_UDID --launch --owner agent \
  --out /tmp/jot-environments.json --json
amoo init --platform ios --app ... --app-id ... --device ... --dry-run --json   # validate only
amoo init device --manifest /tmp/jot-environments.json --device PHONE_UDID --json current_app
amoo init device --manifest /tmp/jot-environments.json --device TABLET_UDID \
  device_launch_app app_id=com.example.jot --arg -UITest --arg fast
amoo init down --manifest /tmp/jot-environments.json --json
```

Android uses the same interface with an absolute APK and running emulator serials.

## Validation, leases and partial failure

Before anything is leased, init checks that the app exists with the right extension, that its own
bundle id matches `--app-id`, and that each device is an available simulator/emulator. An artifact
problem stops the run (it would doom every device). A problem with one device — unknown, or leased by
another session — is recorded and reported as that device's failed result while the others proceed;
if *every* device is unusable nothing starts. `env up` re-checks each lease atomically, so init never
bypasses another session's lease. Setup is sequential so companion builds serialize and port
allocation sees earlier leases. Physical devices are unsupported, as in `env up`. The app digest is
computed once and shared with every `env up`.

## Output

Version-1 JSON: `ok`, `results[]`, optional `error`. Each result uses the env schema: `device`
(id/name/os), `lease`, `platform`, `port`, `holder_pid`, `log`, `app`
(id/path/sha256/installed/launched), version/commit and `error`. Exit 1 means at least one device
failed; successes stay leased until `init down`. `--out` rewrites the file **after every device**, so
an interrupted run still records the leases it took. The file is created `0600` (atomically) and holds
lease ids: keep it private. Lease TTL and ownership checks still apply; neither `init device` nor
`init down` forces another session's lease.

## Remembered locations (`AGENTS.md`)

With consent (`--save` headless, a prompt in a terminal, `--no-save` to skip), init records the **app
artifact**, **app id**, platform and **manifest directory** in a managed block of `./AGENTS.md`
(`--agents-file` to choose another):

```markdown
<!-- amoo:init:start -->
## amoo init
- App artifact: `build/Build/Products/Debug-iphonesimulator/Jot.app`
- App ID: `com.example.jot`
- Manifests: `~/.amoo/init` (lease credentials; never commit)
<!-- amoo:init:end -->
```

Only text between the markers is rewritten. Device ids and lease ids are never saved. The block
seeds the guided defaults and is quoted in headless "missing input" errors. Manifests default to
`~/.amoo/init/<platform>-<timestamp>.json`, one per run, so a later run never overwrites the only
record of earlier leases.

## Recording

CLI leases cannot be adopted by MCP sessions. Run `init down`, then MCP `start_session` per device
with `device_hint`, `app_id` and the same prebuilt `build_path`; only `end_session` exports the
report/plan.

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

The interactive platform picker offers **iOS**, **Android**, and **Both**. Both collects a
simulator `.app` and an Android `.apk`, validates both before setup, and writes separate
platform manifests. The managed AGENTS.md block remembers locations for both platforms,
and later single-platform runs preserve the other platform’s locations.
The framework picker provides artifact guidance for native apps, React Native, Flutter,
and Kotlin Multiplatform. React Native debug builds may require Metro to be started separately.
Terminal prompts use icons and color; `NO_COLOR` or `TERM=dumb` disables color.

With saved repository setup (`--save` or the guided save choice), init also discovers Swift UI-test
harness evidence into `amoo.md` alongside `AGENTS.md`. It does not generate tests or alter targets.
An existing profile is preserved, including reviewed bindings. Review uncertain target, catalog,
launch, and helper conventions before export; see [repository test context](test-context.md).
Recording and export consume its fenced context automatically from the repository working directory.
