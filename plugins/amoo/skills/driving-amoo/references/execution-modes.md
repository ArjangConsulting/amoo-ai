## Choose an execution mode

Subagents delegate work; MCP and CLI execute it; leases reserve devices. A subagent chooses
its own available transport and acquires its own device ownership.

| Task | Recommended mode |
| --- | --- |
| Interactive inspection, debugging, or assertions | MCP when its tools are available; otherwise leased CLI |
| Record a flow or generate tests | MCP managed session (required for the recording pipeline) |
| Run checked-in flows and probe files | Leased CLI (`env up` → `flow` / `probe run` → `env down`) |
| Delegate a bounded verification run | device-verifier subagent, using the applicable mode above |

Check the pinned binary's `--version` and `--help` before choosing CLI commands. Read subcommand
help for required flags; never call an unlisted command (older binaries may enter the REPL).
If `env` is absent, report "this installed version lacks CLI device reservation commands" and
recommend `brew upgrade amoo` for Homebrew installs. Use available MCP managed sessions for
supported checks; missing CLI commands do not mean Amoo has no device ownership. If a required
flow/probe or reporting capability is unavailable, mark that requirement blocked instead of
claiming an equivalent run. Do not upgrade or switch the caller's binary automatically.

For CLI simulator/emulator interaction, acquire ownership before driving:

```sh
amoo env up --platform ios --device <udid> --app-id <bundle-id> --owner amoo-agent --json
# Keep lease, device and port from the result; add --app <build> when installation is needed.
amoo device --platform ios --device <device> --port <port> --lease <lease> device_launch_app app_id=<bundle-id>
amoo device --platform ios --device <device> --port <port> --lease <lease> current_app
amoo env down --lease <lease> --json
```

For Android, use `--platform android` and the emulator serial. Always release in cleanup,
including on failure. For MCP, `start_session` acquires device ownership and `end_session`
releases it; no separate `env up` or CLI lease token is needed. Never use a second transport
to bypass an ownership conflict. Physical devices use explicit IDs and the companion setup below;
`env up` is only for simulators/emulators.
