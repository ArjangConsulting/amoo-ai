# amoo-live: a live device pane for Claude Code

`plugins/amoo-live` is a Claude Code **mod**: a plugin whose TypeScript hooks module runs inside
Claude Code. While an agent drives a device with the amoo CLI (`amoo env up`, `amoo device`,
`amoo flow`, `amoo env down`, run through the Bash tool), it shows:

- **A live mirror** of the device in a side pane, about 2 frames a second on simulators.
- **Separate histories for each leased device**, with a selector when several exist.
- **Pending and completed actions**, their elapsed time and ✓/✗ results, with typed text reduced to its length.
- **Pause, resume and retry controls** for the mirror, plus frame age and measured capture rate.
- **A status line** with the selected device's app and state.
- **The last flow's files**: copyable flow and `report.json` paths, kept after `amoo env down`.
- **Toasts** for a failed `assert_*` call or a failed `amoo flow`.

This implementation is **Claude Code only and experimental**. It is validated with Claude Code
2.1.309; the underlying mods framework requires terminal version 2.1.287 or later. Other clients
continue to use the portable `amoo` plugin. ChatGPT has a different rich-UI extension mechanism;
see [OpenAI integration options](#openai-integration-options).

## Install

Requires the `amoo` CLI. The mod reads the agent's Bash calls, so it needs no server.

```bash
claude plugin marketplace add ArjangConsulting/amoo-ai
claude plugin install amoo-live@amoo
```

A mod loads only in sessions where it is installed or passed with `--plugin-dir`; a plain `claude`
started in this checkout does not pick it up from `plugins/`. To have it in every session while
developing, install it from the checkout. It is then read from this folder, so `/reload-plugins`
picks up edits:

```bash
claude plugin marketplace add /path/to/this/checkout
claude plugin install amoo-live@amoo
```

To start a single session with it from a checkout instead:

```bash
make amoo-live         # mirror with the amoo on PATH (the Homebrew install)
make amoo-live-debug   # build this checkout and mirror with .build/debug/amoo
```

Both run `scripts/amoo-live.sh`, which passes extra `claude` flags through (`make amoo-live-debug
ARGS=--debug`). The debug variant sets `amooPath` through `--settings` for that session only, so
user settings are left alone. Released `amoo` builds (0.2.1 and earlier) do not have `device stream`,
so use the debug variant until it ships. If the stream cannot start or exits, the pane shows its
exit code and last output.

The pane opens as `amoo env up` begins, so it can show a cold start before a runtime id exists. Unasked panes appear at terminals of 144 columns or wider, or 110 columns once the user
has explicitly opened that pane. Below that Claude Code keeps it undrawn and the mod toasts a hint
once per conversation. `/amoo-live` opens it at any width and runs immediately during an agent turn.
The mirror starts after the terminal pane is drawn, so widening the terminal also works.

## Sessions and controls

The mod follows Bash commands that run amoo: `amoo`, a path ending in `/amoo` (such as
`.build/debug/amoo` or `/opt/homebrew/bin/amoo`) or `swift run amoo`, alone or chained with `&&`,
`;` or a pipe, including calls a subagent makes. A device is a **runtime**, keyed by its runtime id:

- `amoo env up` starts one and selects it, from its `--json` report or its `Runtime ID:` line.
- `amoo device <tool>` adds an action to the runtime it names with `--runtime-id`, an
  `AMOO_RUNTIME_ID=` prefix, or an `export AMOO_RUNTIME_ID=` earlier in the same command. A
  `$VARIABLE` set earlier in the command is expanded; one the mod cannot see is not guessed at, so
  the call is left unassigned.
- `amoo flow <file>` adds one action and records the flow and its `report.json` path.
- `amoo env down` ends the runtime.

A runtime the agent leased before the pane saw it (an earlier conversation, another terminal) is
looked up with `amoo env list --json` the first time a call names it. Background Bash runs are not
followed. A `--json` call that is not piped is judged by its own `ok` field; otherwise the Bash exit
status decides, which for a pipeline is its last command's. Discovery calls (`get_capabilities`,
`get_run_telemetry`, `list_devices`) are not listed. Older ended views are pruned as new runtimes
start; running ones are retained.

**Pause mirror** stops capture without ending or changing the device session. **Resume mirror**
starts capture again. An unexpected stream exit, including a signal or a successful exit, shows its
reason and stays stopped across redraws. **Retry mirror** starts a fresh stream without requiring a
new runtime. Closing and reopening the pane preserves a pause or failure; it does not silently
retry. **Close pane** stops capture and hides the pane.

Pending actions show elapsed time, then keep their completion duration and outcome. Failed or
denied startups remain visible until the next startup. Typed values and raw tool error bodies are
not stored in the pane's action history or assertion toasts.

After `amoo env down`, the pane keeps the device's action history and the last flow's paths. Copy
buttons put the flow or report path on the selected surface's clipboard. The ended view never
restarts capture; drive that app again with a new `amoo env up`.

## The mirror

The picture uses the terminal's kitty graphics protocol, so it shows in **Ghostty** and **kitty**.
Other terminals and the desktop, VS Code and mobile surfaces show the text parts only.

Frames come from `amoo device stream` (see `amoo device stream --help`). It is a host-side capture
loop:

- It uses simctl, devicectl or adb, never the companion.
- It takes no device lease and records nothing into a flow report, so generated tests are unchanged.
- It writes `frame-0.png` … `frame-3.png` atomically and prints one JSON line per frame.

The mod spawns one stream for the selected running device while a terminal pane is visible. It
stops on `amoo env down`, pause, switching devices, closing the pane or ending the conversation.
Visibility is checked each second, so switching to another pane or shrinking below the placement
floor stops unused capture too. Desktop, VS Code and mobile text views do not start capture.
Replaced streams cannot write frames or errors into the new view. Temporary frame references are
cleared on stop because the stream removes its files. The stream also exits when its parent dies.

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

- **Hooks entry point:** `hooks/register.tsx`.
- **Reading amoo calls out of a Bash command:** `hooks/cli.ts`.
- **Device state and action tracking:** `hooks/model.ts`, `hooks/actions.ts`.
- **Capture ownership and cleanup:** `hooks/mirror.ts`.
- **Pane rendering and controls:** `hooks/pane.tsx`.
- **`$.state` contract:** `types/index.d.ts`.
- **Tests:** `tests/register.test.tsx`, `tests/lifecycle.test.tsx`, `tests/capture.test.tsx`.
- **Plugin tests:** `AmooPluginTests` checks that the mod is listed only in the Claude marketplace, keeps the amoo version, and that `plugins/amoo` gets no `hooks/` folder. Gemini reads `hooks/hooks.json` from that extension root.

## OpenAI integration options

The portable `amoo` plugin already supplies tools and skills to Codex. The Claude hooks module is
not an OpenAI UI adapter, and no OpenAI panel or viewer is shipped by this mod.

| Surface | Supported extension mechanism | Potential amoo integration |
| --- | --- | --- |
| ChatGPT / Work | MCP Apps, with optional conversation panels, sidebar entrypoints and file viewers | A device/session panel with an action timeline and artifacts |
| Codex CLI | Lifecycle hooks that run scripts or MCP tools | An optional adapter feeding a separate local viewer |
| Amoo Studio | Codex App Server for embedding Codex into an application | A larger integration for conversations, approvals and streamed agent events |

For ChatGPT, start with the standard [MCP Apps UI bridge](https://developers.openai.com/plugins/build/chatgpt-ui):
declare `_meta.ui.resourceUri`, serve a `text/html;profile=mcp-app` resource and use the `ui/*`
bridge and `tools/call`. Keep existing tools useful without UI. Add
[OpenAI conversation-panel entrypoints](https://developers.openai.com/plugins/build/extensions)
only after the portable UI works, and detect supported capabilities rather than assuming every
host renders it. Extension availability varies by surface and plan.

This needs a server and artifact delivery that amoo does not have: it runs no MCP server (a
separate package could add one), and the terminal's local PNG paths are not an image transport for
an iframe. Reuse host capture and session/artifact contracts;
keep observation frames out of the recorded test pipeline. Do not expose companion ports as a
web UI transport.

[Codex lifecycle hooks](https://learn.chatgpt.com/docs/hooks) can observe tool inputs and results,
including shell commands, with `PostToolUse`, and perform cleanup with session lifecycle events. The documented hooks do not
provide Claude's `ui.render` API. Keep any future hook adapter separate from `plugins/amoo/hooks/`
so Gemini cannot accidentally load it. Plugin hooks require explicit user trust and are currently
supported for manually installed Codex desktop plugins, not public-directory submissions; see
[plugin packaging](https://developers.openai.com/plugins/build/plugins).

Local stdio servers have a [desktop-only public distribution route](https://developers.openai.com/plugins/deploy/desktop-only)
whose submission currently requires approved-partner access. A local marketplace prototype and a
public ChatGPT listing therefore have different deployment requirements. For a full Studio-owned
Codex experience, use the [App Server documentation](https://learn.chatgpt.com/docs/app-server).
