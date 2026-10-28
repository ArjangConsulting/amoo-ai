---
name: device-verifier
description: Contract and amoo commands for verifying a built app on iOS simulators / Android emulators and returning a short pass/fail/blocked report — for callers delegating to the device-verifier agent and for the agent itself.
---

# Device verification with amoo

A caller (the main session) builds the app, then hands a YAML contract to the `device-verifier`
agent, which returns only a compact versioned JSON report. The caller's context holds the verdict, not the run.
Install both with the amoo plugin, or `amoo agent install --agent device-verifier` (see `amoo agent`).


Read the repository's AGENTS.md managed init block and amoo.md before setup, recording,
or export. AGENTS.md remembers locations; amoo.md contains reviewed test conventions.
Current CLI generation and MCP start_session discover the nearest amoo.md from their working
directory and read its fenced amoo-context JSON. A prose-only Markdown file is not a test context.
When running elsewhere, pass --context <repo>/amoo.md or context_path=<repo>/amoo.md only if
that file has a valid amoo-context block and the pinned binary supports Markdown profiles.
Otherwise pass an existing test-context JSON file; never invent a path to a missing context.
Explicit context overrides discovery; a plan's embedded context is preserved by generate test.
Profiles may contain separate targetPlatform blocks for iOS and Android; CLI/MCP select the matching block.
Review discovered Kotlin/Java instrumentation evidence as well as Swift harness conventions.
.amoo.json is private CLI runtime state, not a test profile or a reusable flow. Never commit it,
adopt its runtimes into MCP, or automatically install a remembered app artifact.


## Caller: input contract

```yaml
run_id: <caller-generated UUID>
task: "Verify web-player seek fixes"
platforms: [android, ios]                     # run in parallel
builds:
  android: { apk: <path>, app_id: com.example.qa }
  ios:     { app: <path/App.app>, app_id: com.example.qa }
device_prefs:
  android: { avd: Medium_Phone_API_35 }       # reused if running, else booted
  ios:     { runtime: iOS-27.0, model: "iPhone 17e" }
launch_env: { UI_TEST_SKIP_ONBOARDING: "1" }
preconditions:
  - "Use the existing store; reset only when a clean store is requested"
navigate:
  flow: flows/open-first-video.amoo.json      # checked-in amoo flow
checks:
  - probe: scripts/device-probes/00-install-recorder.js   # must pass first
  - probe: scripts/device-probes/10-seek-coalesce.js
  - screenshot: after-navigate
evidence_dir: <scratch>/verify-<timestamp>/
budget: { setup_minutes: 5, total_minutes: 20 }
```

Supply the exact launch_env and resolved build/app identity and device hint from the app's
contract so the verifier can start without rediscovering setup. Forward launch_env as MCP
environment or CLI launch --env values. Reset flags require a requested clean store.

Probes are JavaScript expressions (sync or async IIFEs) run in the app's inspectable WebView,
returning `{probe, pass, details}` as an object or JSON string. Checked-in probes and flows
beat improvised steps: they are what makes two runs comparable.

## Agent: select a mode

Read the `driving-amoo` skill's mode-selection table before setup. Subagents delegate the run;
MCP/CLI execute it; device ownership prevents concurrent runs from interfering.
Prefer controlled CLI for checked-in flows and probes. MCP managed sessions are recommended for
interactive checks and can handle supported checks when the installed CLI lacks `env`.
Check the pinned binary's `--version`, `--help`, and required subcommand help first, then run
doctor before either transport. Use `doctor --cli-only --json` for CLI, or
`doctor --mcp-pid <this-server-pid> --json` for MCP, when listed in help. Follow driving-amoo's
preflight recovery on failure before reporting blocked. Identify your MCP PID from this
connection's build metadata or warning; reconnect your stale server to the pinned binary.
Scoped `--kill-stale` can stop your positively identified server if needed, then reconnect and
recheck its new PID. Routine cleanup of your own server is part of setup unless forbidden;
leave unrelated clients running. If reconnect is unavailable, use controlled CLI for supported
checks after releasing prior ownership. On older binaries, unrelated stale MCP warnings alone
do not block fresh CLI work. Missing doctor or unresolved relevant issues block setup.
Never invoke unlisted commands or silently change the binary.

With MCP, `start_session` owns the device; pass session_id on each call and always end_session.
No separate CLI runtime token is needed. Preserve required flow/probe execution and report/evidence
validation: if available tools cannot fulfill a requirement, mark it not evaluated and report
blocked. Missing `env` means "this installed version lacks CLI device reservation commands";
recommend `brew upgrade amoo` for Homebrew installs, rather than marking all runtimes unsupported.

## Agent: controlled CLI commands

```sh
amoo doctor --cli-only --json
amoo env up --platform android --avd <avd> --app <apk> --app-id <id> --owner device-verifier --json
amoo env up --platform ios --runtime iOS-27.0 --model "iPhone 17e" --app <App.app> --app-id <id> --json
amoo device --platform <p> --device <id> --port <port> --runtime-id <runtime> device_launch_app app_id=<id> --env K=V
amoo flow <flow.json> --device <id> --port <port> --runtime-id <runtime>
amoo probe run <probes…> --platform <p> --device <id> --runtime-id <runtime> --bundle-id <id> \
  --expect-pass --bail --evidence-dir <dir>/<p> --json
amoo env down --runtime-id <runtime> --json
```

Exit codes: 0 ok · 1 failed (probe: a real `pass:false`) · 2 probe could not run (tooling) ·
3 device controlled by another session. `--json` prints one compact object; parse it, don't echo it.

## Rules that keep runs fast and honest

- Simulators/emulators only; amoo never auto-selects a physical device and `env up` refuses one.
- Reuse what exists: `env up` reuses a running emulator/simulator and its installed app;
  relaunch with `device_launch_app` instead of reinstalling or rebuilding. Rebuild only when
  the source changed.
- A runtime (`--runtime-id` / `AMOO_RUNTIME_ID`) is renewed on use and expires after 60 min idle.
- Blocked beats a workaround: two identical tooling failures or 5 minutes of setup → report
  `blocked` with command, error and repro. The caller fixes; the verifier verifies.
- iOS WebViews are reached through the simulator's own Web Inspector (no proxy); Android
  through the WebView devtools socket. Both need the app's debug build to allow inspection.


## Report validation

Use the shared `AgentRunReport` version 1 JSON contract in the device-verifier agent instructions.
Save detailed per-platform evidence locally; the parent receives check outcomes, coverage, provenance
and cleanup with absolute evidence paths. Prefix check IDs by platform and preserve the complete
caller-requested check set, including not-evaluated reasons. Validate before returning:
`amoo agent validate-report --report <path> --run-id <UUID> --checks <all-caller-check-ids>`.
The parent supplies its original run ID and requirements when validating. Successful tool execution
is not a passed assertion; unresolved cleanup, missing checks or truncated evidence prevent pass.
Delegate app/build/device requirements rather than process-owned MCP session IDs.

Compact reports use schema version 2. Seal each regular evidence file with
`amoo agent evidence --path <absolute-file> --run-id <UUID> --checks <associated-check-ids>`.
Include the returned path/hash/run/check manifest entries in `artifacts`. Unknown provenance cannot
support a pass. Caller run ID and checks are required by `validate-report`, including blocked reports.
