---
name: device-verifier
description: Contract and amoo commands for verifying a built app on iOS simulators / Android emulators and returning a short pass/fail/blocked report — for callers delegating to the device-verifier agent and for the agent itself.
---

# Device verification with amoo

A caller (the main session) builds the app, then hands a YAML contract to the `device-verifier`
agent, which returns only a YAML report. The caller's context holds the verdict, not the run.
Install both into a repo with `amoo agent install --target <repo>`.

## Caller: input contract

```yaml
task: "Verify web-player seek fixes"
platforms: [android, ios]                     # run in parallel
builds:
  android: { apk: <path>, app_id: com.example.qa }
  ios:     { app: <path/App.app>, app_id: com.example.qa }
device_prefs:
  android: { avd: Medium_Phone_API_35 }       # reused if running, else booted
  ios:     { runtime: iOS-27.0, model: "iPhone 17e" }
preconditions:
  - "launch env UI_TEST_SKIP_ONBOARDING=1"    # becomes --env; Android gets an Intent extra
navigate:
  flow: flows/open-first-video.amoo.json      # checked-in amoo flow
checks:
  - probe: scripts/device-probes/00-install-recorder.js   # must pass first
  - probe: scripts/device-probes/10-seek-coalesce.js
  - screenshot: after-navigate
evidence_dir: <scratch>/verify-<timestamp>/
budget: { setup_minutes: 5, total_minutes: 20 }
```

Probes are JavaScript expressions (sync or async IIFEs) run in the app's inspectable WebView,
returning `{probe, pass, details}` as an object or JSON string. Checked-in probes and flows
beat improvised steps: they are what makes two runs comparable.

## Agent: commands

```sh
amoo doctor --json                                  # build, stale MCP servers, devices, leases
amoo env up --platform android --avd <avd> --app <apk> --app-id <id> --owner device-verifier --json
amoo env up --platform ios --runtime iOS-27.0 --model "iPhone 17e" --app <App.app> --app-id <id> --json
amoo device --platform <p> --device <id> --port <port> --lease <lease> device_launch_app app_id=<id> --env K=V
amoo flow <flow.json> --device <id> --port <port> --lease <lease>
amoo probe run <probes…> --platform <p> --device <id> --lease <lease> --bundle-id <id> \
  --expect-pass --bail --evidence-dir <dir>/<p> --json
amoo env down --lease <lease> --json
```

Exit codes: 0 ok · 1 failed (probe: a real `pass:false`) · 2 probe could not run (tooling) ·
3 device leased by another session. `--json` prints one compact object; parse it, don't echo it.

## Rules that keep runs fast and honest

- Simulators/emulators only; amoo never auto-selects a physical device and `env up` refuses one.
- Reuse what exists: `env up` reuses a running emulator/simulator and its installed app;
  relaunch with `device_launch_app` instead of reinstalling or rebuilding. Rebuild only when
  the source changed.
- A lease (`--lease` / `AMOO_LEASE`) is renewed on use and expires after 60 min idle.
- Blocked beats a workaround: two identical tooling failures or 5 minutes of setup → report
  `blocked` with command, error and repro. The caller fixes; the verifier verifies.
- iOS WebViews are reached through the simulator's own Web Inspector (no proxy); Android
  through the WebView devtools socket. Both need the app's debug build to allow inspection.
