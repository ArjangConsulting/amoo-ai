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
Run doctor before either transport. Inspect `doctor --help`: CLI work uses
`amoo doctor --cli-only --json`; MCP uses `amoo doctor --mcp-pid <this-server-pid> --json`.
A nonzero exit starts the [recovery procedure](#recover), rather than immediately blocking the task.
Missing doctor or an unresolved issue affecting the selected transport/target blocks that work.
Do not stop unrelated clients to clear a machine-wide diagnostic.
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

### Preflight and stale MCP servers

1. Inspect `issues`, `cli.binary`, and `mcp_servers` from the pinned binary's doctor output.
   A stale MCP process runs an older executable after a rebuild; its presence does not make a
   fresh CLI process or another MCP connection stale. Old checkout/Trash paths may also indicate
   a client configuration that needs correcting. Do not infer ownership from the binary path alone.
2. For CLI work, run `amoo doctor --cli-only --json` when supported. This retains MCP inventory
   but excludes its staleness from the exit status. Resolve remaining target/runtime issues.
   On older binaries without scope flags, inspect `doctor --json`: unrelated stale MCP warnings
   alone do not block CLI work. Do not ignore other issues or silently switch/upgrade binaries.
3. For MCP, get this connection's PID from initialization/tool-result `dev.amoo/build` metadata,
   or the explicit PID in its staleness warning. Current servers supply `doctor_arguments` and,
   only when stale, `stale_cleanup_arguments` as argument arrays. Run them with the selected
   absolute binary as separate arguments, never shell-evaluate metadata. Match the connection's
   binary to the caller's selected build.
   If metadata is unavailable, use the client's MCP diagnostics; never guess from a list of PIDs.
   Reconnect/restart this client's amoo MCP connection using the selected absolute binary path.
   End your reachable sessions first; after reconnecting, old session IDs cannot be reused.
4. If the client cannot stop its stale server, and its PID is positively identified as yours,
   use `amoo doctor --mcp-pid <pid> --kill-stale --json` when supported. Routine cleanup of your
   own server is part of setup unless the caller forbids it; another client's server needs its
   owner's authorization. The command rechecks identity before SIGTERM, allowing normal session
   and companion cleanup. It does not reconnect the client. A nonzero exit may mean the selected
   server has stopped and needs reconnecting; read the refreshed report and cleanup note.
   Never use `pkill`, `killall`, or unscoped `doctor --kill-stale` as routine recovery.
5. Rerun doctor with the reconnected server's new PID before using MCP. If client reconnect is
   unavailable, continue supported inspection/verification through a fresh CLI runtime only after
   releasing your previous ownership. Preserve required checked-in flows/probes and reporting.
   Recording/generation that requires MCP remains blocked until reconnect; report only the
   affected requirements, exact PID/path/error, attempted recovery, and the required client action.

Always release your sessions/runtimes on success and failure. `end_session` releases the device;
`end_session stop_companion=true` also stops its warm companion immediately. Otherwise the companion
idles out (default 120 seconds). MCP stdin closure and SIGTERM perform server cleanup; replacing an
executable while a client keeps its connection open does not end that running process. Do not
terminate a healthy server merely because its task ended; let its client manage the connection.

### Device claims and companion failures

Recover from the signal, not by bulk-killing. None of these needs unscoped `--kill-stale`, and other
clients' servers never need stopping to free a device you can replace.

| Signal | Likely cause | A subagent may | Return to the caller |
| --- | --- | --- | --- |
| `deviceClaimed`; the holder reads `pid N (cmd) since T` | Another session holds the device | Holder **no longer running**: retry once, amoo discards the orphaned claim. Holder is your own session or runtime: `end_session` / `env down --runtime-id`. Otherwise pick another device (`list_devices`, or `env up --avd <other>`) | Holder alive and not yours; a device the caller pinned |
| `doctor` lists `device_locks` or a note naming a stale server | The holder, and which stale MCP server it is | Read-only. Holder is a stale server **you** started: `doctor --mcp-pid <that pid> --kill-stale`, then reconnect | Holder is another client's server |
| Companion `unresponsive` (doctor `companions` / `runtimes`) | Companion accepts connections but does not serve | Your lease: `end_session force=true`, `reset_companion`, `start_session`. CLI: `amoo env down --device <id>` then `env up`. Not your lease: use another device | A companion another client owns |
| Stale MCP servers in `mcp_servers` | Rebuilt binary after start | Unrelated ones do not block; use `--cli-only`. Yours: reconnect | Servers you did not start |
| `Android companion install failed` with an `INSTALL_FAILED_*` code | Read the `Likely cause` and `Recovery` lines in the error | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` / `VERSION_DOWNGRADE`: amoo already removed its own companion packages and retried once; if it persists, `amoo companion install --platform android --device <serial> --force` | Two identical failures on different AVDs |
| `INSTALL_FAILED_OLDER_SDK`, or an API level below 26 | Device older than the companion's minimum | Use an AVD on API 26 or newer | A caller-pinned AVD |
| `INSTALL_FAILED_NO_MATCHING_ABIS`, `INSUFFICIENT_STORAGE`, `USER_RESTRICTED` | Wrong CPU image, full `/data`, or blocked USB installs | Use another AVD (arm64-v8a on Apple silicon); cold-boot with data wiped for storage | Physical-device restrictions |

An emulator that ran both a checkout build and the Homebrew release carries a companion signed with a
different debug key; that is the usual `UPDATE_INCOMPATIBLE`, not an API-level problem.

When a companion install fails, fall back to another AVD or API level: `emulator -list-avds`, prefer an
API 35 image, `env up --avd <other>`, `env down` the failed runtime, and record the switch in `notes`. If the
caller pinned the AVD or API level, report `blocked` with the error text instead. Never use raw `adb install`,
`--force` on a claim, `pkill`, or an unscoped `--kill-stale`.

### Connection failures

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
