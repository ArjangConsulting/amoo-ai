# amoo-live: a live device pane for Claude Code

`plugins/amoo-live` is a Claude Code **mod**: a plugin whose TypeScript hooks module runs inside
Claude Code. While an agent drives a device through the amoo MCP server, it shows:

- **A live mirror** of the device in a side pane, about 2 frames a second on simulators.
- **The session's recent amoo actions**, ✓/✗, with typed text reduced to its length.
- **A status line**: `amoo · <platform> · <app> · rec <recording_health>`.
- **Toasts** for a failed `assert_*` call or a `recording_health` of `failed` at `end_session`.

It is **Claude Code only and experimental**. The mod API is early access and may change between
Claude Code releases. Codex, Gemini CLI, Cursor and Copilot have command hooks but no plugin UI, so
the other clients keep using the `amoo` plugin alone.

## Install

Requires the `amoo` CLI and the amoo MCP server, either from the `amoo` plugin or configured
yourself.

```bash
claude plugin marketplace add ArjangConsulting/amoo-ai
claude plugin install amoo-live@amoo
```

From a checkout, there are two ways to start it:

```bash
make amoo-live         # mirror with the amoo on PATH (the Homebrew install)
make amoo-live-debug   # build this checkout and mirror with .build/debug/amoo
```

Both run `scripts/amoo-live.sh`, which passes extra `claude` flags through (`make amoo-live-debug
ARGS=--debug`). The debug variant sets `amooPath` through `--settings` for that session only, so
user settings are left alone. Released `amoo` builds (0.2.1 and earlier) do not have `device stream`,
so use the debug variant until it ships. If the stream cannot start or exits, the pane shows its
exit code and last output.

The pane opens on the next `start_session`, at terminals of 144 columns or wider. Below that Claude
Code keeps an unasked pane undrawn, so the mod toasts a hint once per session; `/amoo-live` opens it
at any width. The mirror starts when the pane is first drawn, so widening the terminal also works.

## The mirror

The picture uses the terminal's kitty graphics protocol, so it shows in **Ghostty** and **kitty**.
Other terminals and the desktop, VS Code and mobile surfaces show the text parts only.

Frames come from `amoo device stream` (see `amoo device stream --help`). It is a host-side capture
loop:

- It uses simctl, devicectl or adb, never the companion.
- It takes no device lease and records nothing into the session, so the generated plan is unchanged.
- It writes `frame-0.png` … `frame-3.png` atomically and prints one JSON line per frame.

The mod spawns the stream while the pane is open and a session is live. It stops the stream on
`end_session`, on closing the pane, and at session end. The stream also exits when its parent dies.

Each `simctl io screenshot` takes about 0.5 s, so simulators stream at about 2 fps. Captures run
one at a time: simctl serializes overlapping ones, so running several at once only bunches frames
into bursts with longer pauses between them. Physical iOS devices (devicectl) manage about 1 fps.

Options (`/config`, or `pluginConfigs["amoo-live"].options` in settings):

| Option | Default | Meaning |
| --- | --- | --- |
| `amooPath` | `amoo` | The CLI that runs `device stream`; point it at `.build/debug/amoo` for a checkout. |
| `fps` | `6` | Frames per second to aim for, 0.1–30; capture speed caps it. |

## Development

```bash
make mod-check                       # claude plugin validate + claude plugin test
make amoo-live-debug ARGS=--debug    # load the mod with the checkout's amoo and debug logging
```

- **Hooks module:** `hooks/register.tsx`.
- **`$.state` contract:** `types/index.d.ts`.
- **Tests:** `tests/register.test.tsx`.
- **Plugin tests:** `AmooPluginTests` checks that the mod is listed only in the Claude marketplace, keeps the amoo version, and that `plugins/amoo` gets no `hooks/` folder. Gemini reads `hooks/hooks.json` from that extension root.
