# MCP For Local AI

Amoo exposes AI-facing automation through MCP, implemented in Swift over the standard `stdio` transport.
The CLI does not configure or run an AI provider; local AI clients provide the reasoning and call Amoo tools.

## Prerequisites

Use `start_session` for managed sessions. It resolves the device, prepares the companion,
installs an optional `build_path`, and launches the target app. A companion does not need to be
running before the MCP server starts. Pass the returned `session_id` on subsequent calls.

For legacy calls without `session_id`, prepare the default companion yourself. Its host endpoint
is `127.0.0.1:22087` for iOS or `127.0.0.1:22088` for Android. Physical devices need USB forwarding.
Both companions bind IPv4 loopback. Remote network exposure is not a supported deployment mode;
there is no remote authentication/TLS layer. See [prerequisites](prerequisites.md).

Install the CLI with `brew install arjangconsulting/tap/amoo`; no source checkout is required.

## Start the server manually

```bash
amoo mcp serve
```

By default this targets the iOS companion on port `22087`. For Android or custom ports:

```bash
amoo mcp serve --platform android --port 22088
```

That port is the server's default driver for calls without a `session_id`. `start_session` picks its
own companion port per device, so sessions on different simulators or emulators can run at once:
the `port` argument of `start_session` wins, then an explicit `--port` of `amoo mcp serve`, then a
companion already listening on `22087` for that same simulator, and otherwise a stable port derived
from the simulator's UDID (`23000-23999`; Android emulators keep their `22088+` block). If something
else holds the port, `start_session` fails naming the process; pass a free `port` to move off it.

The server speaks JSON-RPC over `stdio` and exits cleanly when the client closes
stdin. It supports both stateless MCP `2026-07-28` requests and the legacy
`initialize` flow used by MCP `2025-11-25` clients.

## Connecting an MCP client

There are two ways to register amoo with an AI client: run the installer script (recommended once
amoo is installed via Homebrew or built locally), or copy the config snippet for your client by
hand. Neither runs automatically — installing amoo (via `brew install` or `swift build`) never
touches another application's configuration on its own; you always trigger this yourself.

### Option A: installer (recommended)

From a Homebrew installation, run from any directory:

```bash
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh"
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh" --client claude-code
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh" --client all --platform android
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh" --dry-run
bash "$(brew --prefix amoo)/share/amoo/install-mcp.sh" --uninstall --client cursor
```

From a source checkout, use `scripts/install-mcp.sh` with the same options. Older Homebrew
packages without the script can use the manual configuration below.

Registration is user-wide: Claude Code uses `--scope user`, and the other clients use their
home-directory configuration files. This makes amoo available across projects for your account.
Uninstall removes the user-wide entry. Existing project-local entries are left intact and may
override it; remove an old Claude Code local entry from that project with
`claude mcp remove --scope local amoo` if you previously used the old installer.
See [Claude Code's scope documentation](https://code.claude.com/docs/en/mcp).

Binary resolution prefers `--bin`, then `amoo` on `PATH` (including Homebrew), then
`brew --prefix amoo`, then a release build in this checkout. The registered path is absolute.
It only ever edits the one `mcpServers.amoo` (or `mcp_servers.amoo`) entry
in each client's user config and previews the change before touching
anything (`--dry-run` shows the diff and stops there). Pass `--bin /path/to/amoo` to point at a
specific binary (e.g. a debug build).

Supported clients: `claude-code`, `claude-desktop`, `codex`, `cursor`, `windsurf`.

### Option B: manual config

Each client reads its own config file. In all of them, `command` should point at the installed
`amoo` binary — with Homebrew that's `$(brew --prefix amoo)/bin/amoo` (typically
`/opt/homebrew/bin/amoo` on Apple Silicon or `/usr/local/bin/amoo` on Intel); resolve it with:

```bash
AMOO_BIN="$(brew --prefix amoo)/bin/amoo"
```

Building from source instead, point `command` at the absolute path to `.build/release/amoo` after `swift build -c
release`, or use `swift run --package-path /absolute/path/to/amoo amoo mcp serve` if you don't want
a separate build step (slower startup, rebuilds on every launch).

**Claude Code** — no config file to hand-edit; use the CLI:

```bash
claude mcp add --scope user amoo -- "$AMOO_BIN" mcp serve --platform ios
```

**Claude Desktop** — `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "amoo": {
      "command": "/opt/homebrew/bin/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

**Codex** — `~/.codex/config.toml` (TOML, not JSON):

```toml
[mcp_servers.amoo]
command = "/opt/homebrew/bin/amoo"
args = ["mcp", "serve", "--platform", "ios"]
```

**Cursor** — `~/.cursor/mcp.json` (same shape as Claude Desktop):

```json
{
  "mcpServers": {
    "amoo": {
      "command": "/opt/homebrew/bin/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

**Windsurf** — `~/.codeium/windsurf/mcp_config.json` (same shape as Claude Desktop):

```json
{
  "mcpServers": {
    "amoo": {
      "command": "/opt/homebrew/bin/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

For Android instead of iOS, use `--platform android` in any of the snippets above. Restart the
client (or reload its MCP connections) after adding or changing the entry.

## Inspect the server during development

```bash
npx @modelcontextprotocol/inspector amoo mcp serve
```

Useful assistant-facing tools include:

- `describe_screen`
- `suggest_test_actions`
- `find_element_by_description`
- `analyze_ai_testability`

Use `analyze_ai_testability` to understand what developers can improve for better AI-driven testing: labels, identifiers, duplicate controls, hidden enabled elements, and missing primary actions.

## Reusable test flows

Keep deterministic smoke tests in a checked-in `*.amoo.json` file and run the whole sequence over
one companion connection:

```bash
amoo flow Examples/sign-in.amoo.json
```

Each step names a normal device/MCP tool. `${name}` in an argument value (anywhere in the string)
resolves from the flow's `"vars"`, then `--var name=value`, then the process environment, so
credentials do not enter source control. Argument values may be JSON strings, numbers or booleans.
The runner stops at the first failed action or assertion and prints the verified result for every
completed step; a step (or the whole flow) with `"on_error": "continue"`, or `--continue-on-error`,
keeps going and the exit code is still 1 if anything failed. `"repeat": N` runs a step N times.
See [`Examples/sign-in.amoo.json`](../Examples/sign-in.amoo.json) for the format.

Flow-only steps cover what used to need a shell loop:

| Step | Arguments | Does |
| --- | --- | --- |
| `wait` | `duration_ms` or `seconds` | Pauses. |
| `wait_for` | `id`/`label`/`contains_text`, `timeout_ms` (default 10000) | Waits for the element (an `assert_visible` with a timeout). |
| `wait_for` | `idle: true`, `stable_ms` (500), `timeout_ms` | Waits until the screen stops changing — first frame after a launch, end of a rotation. |
| `screenshot` | `name` (optional) | Saves `<--output-dir>/NN-<name>.png`, numbered by step. |

One flow can run on several devices at once: `amoo flow f.amoo.json --devices UDID1:22111,UDID2:22112
--output-dir out/` runs them in parallel, writes screenshots to `out/<device>/`, and ends with a
`PASS`/`FAIL` line per device (`${device}` is available as a variable). An iOS entry without
`:port` uses the port derived from its UDID. Flow-only steps are dropped (or, for `wait_for` on an
element, turned into `assert_visible`) by `generate plan --from-flow`.

### Running several companions

`amoo companion start --detach` registers each process, so `amoo companion list` shows pid, platform,
port, state, device and app, and `amoo companion stop --port N` / `--device UDID` / `--all` stops
exactly those (never `pkill`, which also stops other sessions' companions). A process that restarts
its runner now reclaims the port the old runner app left bound instead of failing with "owned by
another companion process".

### Companion lifetime in an MCP server

A session's companion stays warm after `end_session` — starting one is the slow part — and stops
itself after `AMOO_COMPANION_IDLE_SECONDS` (default 120; `0` stops it at once) with no new session
on that simulator. `end_session stop_companion=true` stops it now, which is what to do before an XCTest
run on the same simulator, since two XCTest runners share a device badly (the second swallows taps).

If an `amoo mcp serve` is killed mid-session, its companion is left running with no owner. The next
`start_session` on that simulator adopts it when it still answers, and retires it when it does not —
only a runner whose parent process is gone is touched, never one another live amoo is using.
`reset_companion` does the same on demand for a wedged companion, and `companion_status` with a
`session_id` probes that session's connection (`rpc_ms`, foreground app) instead of the build state.

### Tap safety and scrolling

`tap_element` reads the hierarchy before tapping and refuses a target that another control (a
keyboard key, a sheet) is painted over, that a clipping container (a tab pill, a scroll view) cuts
off, or whose tap point is off-screen. The check is on by default but best effort: it gives up after
`hittable_timeout_ms` (1500) and taps unchecked, so a very dense screen never slows every call.
`check_hittable=true` makes it required; `false` skips it. It always reports
`foreground_changed` when the tap left the app (Siri, a system sheet), and compares the screen before
and after the tap — within `effect_timeout_ms` (1500), `check_effect=false` to skip — so a tap that
moved nothing says "No observable change" (`observable_change=false`) instead of reading as success.
`scroll`'s direction names where to scroll (`down` reveals content below; `swipe_in_direction`
names the finger's direction instead). `scroll_to_element` scrolls until a target is on screen, and exports
(a swipe-until-hittable loop in XCUITest, `scrollTo()` in Espresso, `performScrollTo()` in Compose);
`dismiss_keyboard` tries Return, a Hide/Done button, then a swipe — `press_key return` does nothing
on a number pad. Deadlines are 12s per call; set `AMOO_RPC_TIMEOUT_SECONDS` (1–600) when a very
large accessibility tree needs longer.

## Reviewing screenshots

`amoo flow ... --output-dir shots/` (or `take_screenshot output=`) leaves a folder of PNGs. Two
offline commands turn it into something reviewable, with no extra tooling:

```bash
amoo shots montage shots/ --columns 4          # one captioned contact sheet: shots/contact-sheet.png
amoo shots diff baseline/ shots/ --out diffs/  # per-file same / CHANGED / MISSING / SIZE / NEW, exit 1 on any change
```

`diff` counts a pixel as changed when any colour channel moves by more than `--tolerance` (8), and
fails a file when more than `--threshold` (0.1%) of its pixels changed; `--out` writes a red overlay
of each failing file. Both need CoreGraphics, so they run on macOS only.

## Generating tests from a recorded session

The canonical workflow is `start_session` → drive the app → `end_session` → inspect `plan.json` →
`amoo generate test`. `end_session` **already** compiles the recorded history and writes
`plan.json` + `flow.json`; `compile_session_to_plan` is an optional preview you can call earlier,
while the session is still open, and it does not change the plan `end_session` writes. `amoo
generate test --plan` turns that plan into a standalone XCUITest / Espresso file.

amoo's own lifecycle calls (`start_session`, `end_session`, `compile_session_to_plan`,
`get_session_report`, …) are never recorded as app-under-test steps, so a complete app-interaction
recording generates without `--allow-incomplete` and with no trailing `XCTFail` — not even when an
explicit `compile_session_to_plan` preceded `end_session`.

To make the generated file fit a host test target — its base class, launch/assertion helpers, and
identifier catalog — pass an **app-owned test context**. Agents can supply it at session or compile
time (`start_session` / `compile_session_to_plan` accept `context_path` or `context_json`), and it
is persisted with the session so an `end_session` recompile keeps it. See
[`docs/test-context.md`](test-context.md) for the schema.

Offline, recompile a recorded `report.json` without re-running the server:

```bash
amoo generate plan --report report.json --context test-context.json --out out/
amoo generate test --plan out/plan.json
```

To author a plan with no recording at all, compile the same `*.amoo.json` flow `amoo flow` runs:

```bash
amoo generate plan --from-flow Examples/sign-in.amoo.json --test-name SignIn --out out/
amoo generate test --plan out/plan.json
```

## Efficient and reliable clients

### Diagnosing a closed transport

Set `AMOO_MCP_DIAGNOSTICS=1` in the MCP client's server environment and capture server stderr.
Keep stdout exclusively for JSON-RPC. Diagnostics contain a timestamp, server PID, and lifecycle
event; they omit request arguments and app content. Default operation emits no lifecycle logs.

- `started`: the stdio loop began.
- `stdin_eof`: all client input writers closed; outstanding requests are draining.
- `requests_drained`: the stdio loop returned normally; CLI session/companion cleanup follows.
- `input_oversized_frame` or `input_error`: the input loop failed.
- `output_error`: writing a response failed, for example because the client closed its read pipe.
  The CLI ignores SIGPIPE and immediately enters cleanup, even when client input stays open.

A fatal signal inside `amoo mcp serve` (a Swift runtime abort, a trap, a segfault) is also recorded in
`~/Library/Logs/amoo/mcp-serve-crash.log` (`AMOO_CRASH_LOG` overrides) and on stderr, so a client
that only reports "Connection closed" leaves a trace.

Collect `amoo doctor --json` before and after a reproduction, the exact failing tool and timestamp,
and the client's MCP logs/exit status. A missing session should return `session_not_found` while a
subsequent `ping` still succeeds. Separate MCP server processes cannot attach to each other's live
session IDs; disk reports preserve history, not a live driver. Delegate app/build/device requirements
and expected assertions, and start a session in the receiving context on an available device.
End the owning session before reusing its device; keep exact current-screen work with the owner.

### Reducing calls without weakening verification

Set `AMOO_TOOL_PROFILE=drive`, `record`, or `audit` in the MCP process environment to advertise a
smaller task-specific catalog; `all` preserves the full catalog. Tool names and contracts remain
stable. Load `plugins/amoo/skills/driving-amoo/SKILL.md` first and its recording/coordinate references only when
needed. Contributor skills are not required to operate the device.

`describe_screen` derives context, actionable elements, and `screen_token` from a single hierarchy
observation. Tokens detect changes in labels, values, geometry, visibility, and tree order within
companion hierarchy limits. They are change hints, not durable selectors or proof of readiness.
Use explicit assertions as postconditions. Mutations reject ambiguous matches; refine with IDs
and `parent_id`, or, when several elements are truly indistinguishable (iPadOS 27's top tab bar
exposes each tab twice), pick one with `index` (0-based, in the device's order) or `first: true` on
`find_elements`, `tap_element` and the `assert_*` tools. A recorded pick becomes
`.element(boundBy:)` / `.firstMatch` in the generated XCUITest, a `withIndex(...)` matcher in
Espresso, and `onAllNodes(...)[n]` in Compose (`set_text` / `fill_field` take no pick yet). `find_elements` also prints each element's current `value` (never for secure fields,
and never written to the session report) and, for a whole-screen listing, hides repeated-label static
text and scroll bars unless `include_noise=true`. A timeout can occur after a device action started: inspect before retrying.

#### Selector constraints

`id`, `label` and `contains_text` are **constraints, and all of them must match**. `assert_visible
id=day.30 contains_text="Range end"` passes only for an element that has that identifier *and* a
label containing the text; a correct identifier with the wrong text fails. `parent_id` scopes the
search to that element's descendants before any constraint applies, and `index` / `first` pick among
the survivors afterwards. `description` / `field_description` are natural-language guesses, not
constraints, so combining one with an exact field is rejected with `invalid_argument` rather than
ignored. For `swipe_in_direction`, `element_id` and `element_label` follow the same rule. (Before,
the host used the first of `id`, `label`, `contains_text` and dropped the rest, so such a call
passed on the identifier alone; the companions have always matched every field they were sent.)
`parent_id` was likewise a no-op on a real device: the request carried the parent, but neither
companion read it, so a day "under" a button that had no children still matched. The host now
applies the scope itself from the companion's view hierarchy — the parent must resolve to exactly
one element (several is `ambiguous_selector`, none matches nothing), only its descendants are
candidates, and if the hierarchy cannot be read the call fails with `scope_unavailable` instead of
quietly running unscoped.
The same constraints reach `report.json`, `plan.json` and every emitter: XCUITest chains
`.matching(identifier:)` and `NSPredicate` filters, Espresso uses `allOf(…)` with
`isDescendantOfA(…)`, and Compose joins matchers with `and` and `hasAnyAncestor(…)`.

#### Asserting selection

`assert_selected` (`id`/`label`/`contains_text`/`description`, `expected=true|false`, default
`true`, `timeout_ms`, `parent_id`, `index`/`first`) polls until an **existing** element's selected
state equals `expected`. An absent element fails even for `expected=false`; the failure reports
`selector`, `expected`, `observed` (`selected`, `unselected`, `not_found`) and
`resolution_failed`. Duplicate matches are `ambiguous_selector`, as for every other assertion. A
device that reports no selected state returns `selected_state_unsupported`; visibility, enabled
state and `assert_value` are never substituted (they cannot see the selected trait). iOS reports
the state; Android does not yet, so Android recordings cannot contain the assertion and the
Espresso/Compose emitters refuse a hand-written one.

`find_elements` prints each element's `selected` state, but that is an observation: it is never
compiled into an assertion. When a recorded observation read a selected state, the plan carries a
`selected_state_not_asserted` warning naming the action and the state, so the gap is visible.

`find_elements`, `list_apps`, `list_sessions`, and `get_session_report` default to 50 results;
use `limit` and `next_offset` while `has_more` is true. Offsets query live state, so keep the screen
stable while paging and restart if it changes. Hierarchy output defaults to 200 nodes with an
explicit truncation marker. Truncated output cannot establish absence. Screenshots can be saved
without returning image tokens: pass `output` and `return_image=false`. Use `scale` to reduce
image dimensions. Reusable deterministic action sequences can use `amoo flow` to avoid a model
round trip per action.

Requests execute independently across devices and serialize per device within one server process.
Cancellation notifications propagate to outstanding request tasks. RPC deadlines and bounded input
frames prevent indefinite client work; device-side cancellation may finish later. Production
session bootstrap holds an OS file lock until session cleanup, rejecting a second MCP process on
the same device as well as conflicting environment runtimes. Queued calls cancel promptly; an active
mutation keeps its place until its backend stops. Recovery calls have reserved request capacity.

Output runs on a separate worker with a 16 MiB queue limit and a five-second write deadline.
EOF allows two seconds for pending responses, then cancels remaining requests before session
cleanup. SIGTERM follows the same cleanup path. Assertions propagate their remaining monotonic
deadline into RPCs and subprocesses; a late read cannot turn an expired assertion into success.
Required hittability inspection must succeed before a tap; best-effort taps report
`hittability_checked=false` when inspection was unavailable.

Reports flush after ten pending actions or five seconds of idle time, and at orderly shutdown.
Pending writes coalesce per session, and session listings use lightweight summaries. The persisted
report remains a complete snapshot; very long recordings still have snapshot rewrite costs.
An abrupt crash can lose the pending batch. `get_session_report` and `end_session` expose
`recording_health`: saved, pending, failed, unknown (no observed write), or disabled. A device action
can succeed while persistence fails; `saved` covers the latest queued generation, not an older write; check this field before claiming the recording is durable. Known entered secrets and sensitive launch metadata
are redacted across recorded arguments, results, and observed selectors. `record_value=fixture`
explicitly preserves non-sensitive sample text for generation. Redacted values require runtime
bindings before complete test export. Screenshots can still contain sensitive pixels: choose
appropriate fixture data. Do not put secrets in test names or app-owned context files.

Audit results describe the inspected screen and include per-rule evidence coverage. No findings
is not a whole-app security certification; deep-link validation requires scenario evidence.

For a short known sequence, `run_steps` accepts an active `session_id` and an array of up to 20
`{"tool":"…","arguments":{…}}` objects. Actions and assertions execute in order under the same
device queue, stop at the first failure, and each attempted step is recorded once. Nested batches,
lifecycle calls and per-step session overrides are rejected before execution. Per-step timeouts
are capped at 10 seconds and gesture durations at 3 seconds. Completed actions are not rolled back.
Use normal discovery calls to decide the sequence first; batch responses contain compact summaries.

### Testing a release executable

Run `python3 scripts/ci/mcp-smoke.py /absolute/path/to/amoo` before distributing a build. It checks
initialization, device discovery, request IDs, recovery after a tool error, EOF, output disconnect,
and SIGTERM without booting or driving a device. `--fatal-signal` also validates the preallocated
fatal-signal diagnostic in a child process. Release artifacts include the compiler version and
dependency lockfile; use initialization's `dev.amoo/build` metadata to identify the running binary.
