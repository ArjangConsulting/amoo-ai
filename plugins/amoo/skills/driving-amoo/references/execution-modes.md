## Who drives

| Task | Who and how |
| --- | --- |
| Inspection, debugging, assertions | `amoo device --runtime-id <id> --json <tool>`, output filtered locally |
| A check that will be repeated | `amoo` subagent with `goal: author-flow`; the caller reruns the returned flow |
| Bounded check with an explicit expected result | `amoo` subagent (repo-local name may be `amoo-debug`) |
| Run checked-in flows and probe files | `env up` → `amoo flow` / `amoo probe run` → `env down` |
| Generate a test | Author a flow, then `amoo generate plan --from-flow` → `amoo generate test` |
| Prepare several devices from one build | `amoo init --platform --app --app-id --device ... --out <manifest> --json` |
| Verify built artifacts with checked-in flows and WebView probes | `device-verifier` skill and subagent |
| Visual discovery, decisions between steps, source changes | Main context with `driving-amoo` |

`driving-amoo` is a skill; `amoo` and `amoo-debug` are subagents. Pass app_id, build_path,
device_hint and the exact launch_env from the app's setup contract; add reset flags only for a
requested clean store. Delegate on the cheapest model that reliably does bounded device work, chosen
on each spawn; retry on a stronger one only when the cheaper one blocks or returns an unusable report.

## Runtimes

A runtime is your lease on one simulator or emulator and its companion. Take one before driving and
release it on success and failure:

```sh
amoo env up --platform ios --device <udid> [--app <build>] --app-id <bundle-id> --owner amoo-agent --json
amoo device --runtime-id <runtime> --json device_launch_app app_id=<bundle-id>
amoo flow <file.amoo.json> --runtime-id <runtime> --output-dir <evidence>
amoo env down --runtime-id <runtime> --json
```

`--runtime-id` (or `AMOO_RUNTIME_ID`) supplies the platform, device and port; an explicit `--device`
or `--port` still wins. Android uses `--platform android` with an emulator serial or `--avd <name>`.
`env up` reports `timings_ms` and `companion.phases` (whether the build and install were reused).
`env up --runtime-id <id>` reuses a healthy runtime and recovers an unhealthy one, keeping its identity;
a reused runtime keeps its running companion, so after a companion change use `env down` then `env up`.
Physical devices take explicit IDs and their own setup; `env up` is only for simulators and emulators.

For several devices, build once and `amoo init` (`--dry-run` validates first). Read every entry of
`results[]` even when the exit status is 1, use its `runtime_id` for `device`/`flow`, and clean up with
`amoo init down --manifest <path> --json`.

## Writing a flow

`tap_element`, `scroll_to_element` and `screenshot` steps already wait for the screen to settle; do not
add `wait_for` with `idle` after them. Use `wait_for` with an `id` for an element that appears later.
Give every state-changing tap its postcondition with `expect_id` / `expect_label` (`expect_absent=true`
for one that goes away): the flow fails that step when it is not met. `"optional": true` is only for a
step whose outcome does not matter, never to make a failing check pass on some devices; `"on_error":
"continue"` keeps going but still fails the run. Put the app id and launch environment in `vars`, never
device IDs or ports. `--output-dir` gets `report.json` with every step's status, timing and last
observed state.

## Iterate without rebuilding

Each device call should answer in about a second; a slower one is worth reporting. Start from a
booted device with the app installed and relaunch with `device_launch_app`, which always starts a fresh
process. Rebuild the app only after its source changes; a reinstall keeps app data, so uninstall
through amoo first when a run must start clean. For XCTest suites, `build-for-testing` once, then
`test-without-building -only-testing:<Target>/<Suite>/<test>()`.

## Recover

Read the error text: amoo names the cause and the command that fixes it. Never bulk-kill.

| Signal | A subagent may | Return to the caller |
| --- | --- | --- |
| `deviceClaimed`, holder `pid N (cmd) since T` | Holder no longer running: retry once. Your own runtime: `env down --runtime-id`. Otherwise pick another device | Holder alive and not yours; a device the caller pinned |
| Runtime `unresponsive` or `stale` (`amoo env list`, `amoo doctor --json`) | `amoo env up --platform <p> --runtime-id <id>` | Someone else's runtime |
| A launch reports a system dialog in front (`blocking_dialog`) | Tap one of its buttons by id (`aerr_wait`, `aerr_close`), then relaunch | Repeated ANRs on the same device |
| The companion's own app is in front | `amoo env up --runtime-id <id>` | — |
| `Android companion install failed` with `INSTALL_FAILED_*` | Follow its `Recovery` line; amoo already retried `UPDATE_INCOMPATIBLE` once. Otherwise another AVD on API 35 | A caller-pinned AVD or API level |
| Connection error | Read `$TMPDIR/companion-launch-<port>.log`, then `env up --runtime-id <id>` once | Two identical failures |

After a timeout, inspect state before repeating a mutation: it may already have run. Launch,
terminate and reinstall the app only through amoo (`device_install_app`, `device_launch_app`,
`device_terminate_app`); raw `simctl`/`adb` app lifecycle desyncs the companion. `device_launch_app`
binds the launched app as the target; for an app that is already running, call `set_target_app` first.
Never use `--force` on a claim, `pkill`, or raw `adb install`.

## Deadlines

Count in-flight setup calls against the caller's budget (default setup limit: 5 minutes). Bound each
CLI setup process with an external timeout, give a `device_boot` attempt 60 seconds, inspect device
state and retry at most once. Never start a duplicate boot while the first is unresolved. Stop at the
deadline and mark unchecked screens as not evaluated. Boot stages are logged to unified logging:
`log show --info --last 5m --style compact --predicate 'subsystem == "amoo"'`.
