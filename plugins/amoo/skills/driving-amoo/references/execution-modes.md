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
| Delegate a bounded verification run | device-verifier subagent, using the applicable mode above |

Check the pinned binary's `--version` and `--help` before choosing CLI commands. Read subcommand
help for required flags; never call an unlisted command (older binaries may enter the REPL).
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
