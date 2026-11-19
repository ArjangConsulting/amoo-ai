---
name: device-verifier
description: Contract and amoo commands for verifying a built app on iOS simulators / Android emulators and returning a short pass/fail/blocked report — for callers delegating to the device-verifier agent and for the agent itself.
---

# Device verification with amoo

A caller (the main session) builds the app, then hands a YAML contract to the `device-verifier`
agent, which returns only a compact versioned JSON report: the caller's context holds the verdict, not
the run. Install both with the amoo plugin, or `amoo agent install --agent device-verifier`.

## Caller: input contract

```yaml
run_id: <caller-generated UUID>
task: "Verify details navigation and state"
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
  flow: flows/open-details.amoo.json      # checked-in amoo flow
checks:
  - probe: scripts/device-probes/00-ready.js   # must pass first
  - probe: scripts/device-probes/10-details-state.js
  - screenshot: after-navigate
evidence_dir: <scratch>/verify-<timestamp>/
budget: { setup_minutes: 5, total_minutes: 20 }
```

Supply the exact launch_env and the resolved build, app identity and device preference so the verifier
starts without rediscovering setup. Bundle all checks for one screen into one delegation: even a
blocked run pays the startup cost. Checked-in flows and probes beat improvised steps; they are what make
two runs comparable.

Probes are JavaScript expressions (sync or async IIFEs) run in the app's inspectable WebView, returning
`{probe, pass, details}` as an object or JSON string. iOS WebViews are reached through the simulator's
Web Inspector; Android through the WebView devtools socket. Both need a debug build that allows
inspection.

## Commands

```sh
amoo doctor --json
amoo env up --platform android --avd <avd> --app <apk> --app-id <id> --owner device-verifier --json
amoo env up --platform ios --runtime iOS-27.0 --model "iPhone 17e" --app <App.app> --app-id <id> --json
amoo device --runtime-id <runtime> --json device_launch_app app_id=<id> --env K=V
amoo flow <flow.json> --runtime-id <runtime> --output-dir <dir>/<p>
amoo probe run <probes…> --runtime-id <runtime> --bundle-id <id> --expect-pass --bail --evidence-dir <dir>/<p> --json
amoo env down --runtime-id <runtime> --json
```

Exit codes: 0 ok · 1 failed (probe: a real `pass:false`) · 2 probe could not run (tooling) · 3 device
controlled by another session. `--json` prints one compact object; parse it, don't echo it.

## Rules that keep runs fast and honest

- Simulators and emulators only; `env up` refuses a physical device.
- Reuse what exists: `env up` reuses a running emulator/simulator and its installed app; relaunch with
  `device_launch_app` instead of reinstalling. A reinstall keeps app data; default-value checks need a
  requested clean store (uninstall through amoo first), which still cannot clear Keychain or server state.
- Use `precondition=true` on setup assertions: a mismatch blocks coverage rather than proving a product
  defect, and a passed precondition alone does not establish the requested behavior.
- Blocked beats a workaround: two identical tooling failures or 5 minutes of setup → report `blocked`
  with command, error and repro. The caller fixes; the verifier verifies.
- Signed-in checks use `credential="<profile>#<field>"` from the project's `amoo.config.json`, never a
  typed password (driving-amoo `references/credentials.md`).
- Recovery from claims, unhealthy runtimes and install failures: driving-amoo
  `references/execution-modes.md`, "Recover".

## Report validation

The report contract is in the device-verifier agent instructions. Prefix check IDs by platform and keep
the complete requested check set, including not-evaluated reasons. Seal evidence with `amoo agent
evidence` and validate with `amoo agent validate-report --report <path> --run-id <UUID> --checks
<all-caller-check-ids>` before returning. Successful tool execution is not a passed assertion;
unresolved cleanup, missing checks or truncated evidence prevent a pass.
