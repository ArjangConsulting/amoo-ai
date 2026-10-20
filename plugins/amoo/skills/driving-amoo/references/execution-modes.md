## Choose an execution mode

Subagents delegate work; MCP and CLI execute it; runtime records track companions and access locks protect device control. A subagent chooses
its own available transport and acquires its own device ownership.

| Task | Recommended mode |
| --- | --- |
| Interactive inspection, debugging, or assertions | MCP when its tools are available; otherwise controlled CLI |
| Record a flow or generate tests | MCP managed session (required for the recording pipeline) |
| Run checked-in flows and probe files | CLI runtime (`env up` → `flow` / `probe run` → `env down`) |
| Prepare several devices from one build | `init` (guided, terminal) or `init --platform --app --app-id --device ... --out <manifest>` (agents) |
| Install repository skills/client configuration | `init repo --target <repo> [--client <name>]` |
| Bounded check with an explicit expected result | `amoo` subagent (repo-local name may be `amoo-debug`); compact JSON verdict and evidence paths |
| Visual discovery or a flow needing decisions between steps | Main context with `driving-amoo` |
| Source changes | Main context; device subagents never edit source |
| Verify built artifacts with checked-in flows and WebView probes | `device-verifier` skill and subagent |

`driving-amoo` is a skill to load; `amoo` and repo-local `amoo-debug` are subagents to delegate to.
Do not try to load amoo-debug as a skill. Pass app_id, build_path, device_hint, and exact
launch_env from the app's setup contract. Include reset flags only for a requested clean store.
Do not delegate a flow that needs a question answered midway; keep it in the main context.

Check the pinned binary's `--version` and `--help` before choosing CLI commands. Read subcommand
help for required flags; never call an unlisted command (older binaries may enter the REPL).
Run `amoo doctor --json` before either MCP or CLI device work. Missing/failing doctor blocks
setup. Inspect stale MCP processes and binary paths, reconnect affected clients to the pinned
build, and rerun doctor before trusting results. Stop and report the blocker if reconnecting is
unavailable. `doctor --kill-stale` requires authorization to stop stale servers across clients.
If `env` is absent, report "this installed version lacks CLI device reservation commands" and
recommend `brew upgrade amoo` for Homebrew installs. Use available MCP managed sessions for
supported checks; missing CLI commands do not mean Amoo has no device ownership. If a required
flow/probe or reporting capability is unavailable, mark that requirement blocked instead of
claiming an equivalent run. Do not upgrade or switch the caller's binary automatically.

For CLI simulator/emulator interaction, acquire ownership before driving:

For multi-device setup, build once externally and reuse the identical artifact. A person runs bare
`amoo init` for the guided flow; agents (no terminal) must pass `--platform`, `--app`, `--app-id` and
`--device`, and get every missing input listed at once. `AGENTS.md` may hold the app/manifest locations
under `## amoo init`.

```sh
amoo init repo --target /path/to/repo --client codex --client claude --json
amoo init --platform ios --app /path/to/Jot.app --app-id com.example.jot \
  --device <phone-udid> --device <tablet-udid> --launch --out /tmp/amoo-init.json --json  # add --dry-run to validate only
amoo init device --manifest /tmp/amoo-init.json --device <phone-udid> --json current_app
amoo init down --manifest /tmp/amoo-init.json --json
```

Read `results[]` even when exit status is 1: successes remain controlled until cleanup. Each
entry carries its device, runtime_id, port, companion_pid, log, app identity/hash and install/launch
status. Use those runtime_id/device/port fields directly for `amoo flow` or `probe run`.
The manifest is an ownership credential, not an MCP session. To record, release it with
`init down`, then start_session on each selected device with the same prebuilt build_path.
Do not transfer a CLI runtime to MCP or rebuild the app per device. Companion builds may
still occur when companion products are missing or changed. Check help first on older binaries.

For a single device or selection by runtime/model/AVD, `env up` remains available:

```sh
amoo env up --platform ios --device <udid> --app-id <bundle-id> --owner amoo-agent --json
# Keep runtime, device and port from the result; add --app <build> when installation is needed.
amoo device --platform ios --device <device> --port <port> --runtime-id <runtime> device_launch_app app_id=<bundle-id>
amoo device --platform ios --device <device> --port <port> --runtime-id <runtime> current_app
amoo env down --runtime-id <runtime> --json
```

For Android, use `--platform android` and the emulator serial. Always release in cleanup,
including on failure. For MCP, `start_session` acquires device ownership and `end_session`
releases it; no separate `env up` or CLI runtime token is needed. Never use a second transport
to bypass an ownership conflict. Physical devices use explicit IDs and the companion setup below;
`env up` is only for simulators/emulators.

## Iterate without rebuilding

Every device call should answer in about a second; a slower one is an amoo bug worth reporting,
not something to wait out. Most of a slow loop is rebuilding what has not changed:

- **Reuse pre-booted devices.** Start from a simulator/emulator that is already booted with the
  app installed; relaunch with `device_launch_app` rather than rebooting, reinstalling or
  rebuilding. `amoo env up` reuses a running AVD/simulator and its installed app.
- Keep one companion running per device across app rebuilds. `companion start` rebuilds it only
  when companion sources change.
- Rebuild the app only after its source changes. A hang, crash, or flaky result is re-run on the
  existing build: `device_launch_app` always starts a fresh process. A reinstall keeps the app's
  data and restored state; uninstall first when a run must start clean.
- For XCTest suites, `xcodebuild build-for-testing` once, then run each attempt with
  `test-without-building -only-testing:<Target>/<Suite>/<test>()` (Swift Testing needs the `()`).

## Shared machines and agents

For several devices, build the app once externally, then `amoo init` (guided in a terminal; agents pass
`--platform --app --app-id --device ... --out <manifest> --json`, validate with `--dry-run`). Each device gets
its own runtime, companion and port from that one artifact; never rebuild per device. `AGENTS.md` may record
the app and manifest locations under `## amoo init`. Commands, manifest use, cleanup and the recording
hand-off (stop CLI runtimes, then MCP `start_session`) are described above.

Live session IDs are local to one MCP server process; a separate agent server cannot attach.
Delegate app/build/device requirements, then start_session in the receiving context on an available
device. The owner must end_session before its device is reused. To preserve the exact current
screen, keep driving in the owning context. Never drop session_id after an attachment error.

Other sessions may be driving devices on the same Mac. `amoo env up --platform <p> [--avd|--runtime
--model] --app <build> --app-id <id> --json` starts a runtime on a simulator/emulator (never a physical one),
starts its companion on a free port in the background, and returns `runtime`, `device`, `port`;
pass `--runtime-id` (or `AMOO_RUNTIME_ID`) to `amoo device`/`flow`/`probe run`, and `amoo env down --runtime-id`
when done. For a bounded assertion, delegate to the `amoo` subagent (some repositories call it
`amoo-debug`); load `driving-amoo` as a skill. For checked-in flow/probe contracts, use the
`device-verifier` skill and subagent. Keep discovery, judgment between steps, and source edits in
the main context. Pass app_id, build_path, device_hint, and the exact launch_env; enable a reset
flag only for an explicitly requested clean store.

## Recover

For client-level `Transport closed`, capture MCP stderr with AMOO_MCP_DIAGNOSTICS=1 and compare
amoo doctor --json before/after. A missing session is a tool error, not proof the transport closed.

A connection error may mean a stopped companion, disconnected device, or wedged test runtime.
Read the returned error code and device/session state. Follow the reported companion-start
command when applicable; preserve session_id and target identity. Do not blindly repeat a
mutation after timeout: inspect the postcondition first, because it may already have executed.

Once a session is live, launch/terminate/reinstall the app-under-test only through amoo tools
(`device_install_app`, `device_launch_app`) — never raw `simctl`/`adb`. The companion survives a
reinstall; the app is left not running, so launch it before querying it again. If a device tool
fails with a connection error, read `$TMPDIR/companion-launch-<port>.log`, then restart the
companion; `companion_status` can briefly still report ready, so it is not proof the channel works.

`device_launch_app` binds the launched app as the target. To drive an app that is already running,
call `set_target_app` first: with no target bound, the iOS companion reports `com.apple.springboard`
as frontmost even while another app is on screen.

Use the documented system scope for permission prompts. Do not guess that an app's controls
are system UI merely because their labels contain words such as time or settings.
For WebViews, read [the transport prerequisites](https://github.com/ArjangConsulting/amoo-ai/blob/main/docs/webview-introspection.md).
