# Amoo Mobile Testing

Swift-first mobile testing infrastructure for iOS and Android, with:

- protocol-based drivers
- gRPC companion communication
- a CLI for people, scripts and AI agents
- deterministic automation first, AI workflows second

## Repo Layout

- [Sources](Sources): Swift packages for drivers, protocol, server, CLI
- [CompanionApps](CompanionApps): iOS and Android companion apps
- [Tests](Tests): unit and integration tests
- [scripts](scripts): CI and local helper scripts

## Install

```bash
brew tap arjangconsulting/tap
brew install amoo
```

Homebrew installs a prebuilt CLI and the companion projects. No amoo source checkout is needed.

## Quick Start (Homebrew)

For iOS, use macOS 15+ with Xcode and an installed simulator runtime:

```bash
brew install protobuf xcodegen
amoo preflight --platform ios
amoo env up --platform ios --app-id <bundle-id> --json
amoo device --runtime-id <runtime> --json current_app
amoo env down --runtime-id <runtime> --json
```

For physical iOS devices, also install `libimobiledevice`. For Android, install a supported
JDK (17–26) and Android SDK, then use `--platform android`:

```bash
brew install --cask temurin@21
amoo preflight --platform android
amoo env up --platform android --avd <name> --app-id <package> --json
```

`amoo env up` leases a simulator or emulator and starts its companion; pass the `runtime_id` it prints
to `amoo device` and `amoo flow`, and release it with `amoo env down`. `amoo device` with no tool lists
every tool and its arguments. Reusable sequences are checked-in flows (`amoo flow <file.amoo.json>`),
which `amoo generate plan --from-flow` and `amoo generate test` turn into XCUITest or Espresso tests.
See the [tool guide](docs/device-tools.md) and [prerequisites](docs/prerequisites.md).

## Use amoo from any AI agent

The **amoo plugin** ([`plugins/amoo`](plugins/amoo)) packages what an AI coding agent needs to
use amoo:
- **The `amoo` subagent.** Your agent delegates a device task to it: inspect, verify, debug,
  record a flow or generated test, or audit. It returns a compact versioned JSON report, not the whole
  device transcript.
- **The `device-verifier` subagent.** It runs a contract-driven verification with checked-in
  probes.
- **The `driving-amoo` and `device-verifier` skills.**

The agents drive devices with the amoo CLI, so the plugin needs no server.

Every route below needs the `amoo` CLI itself, installed with Homebrew (see [Install](#install)).

| Client | Install |
| --- | --- |
| Claude Code | `claude plugin marketplace add ArjangConsulting/amoo-ai` then `claude plugin install amoo@amoo` |
| GitHub Copilot CLI | `copilot plugin install ArjangConsulting/amoo-ai:plugins/amoo` |
| Codex | `codex plugin marketplace add ArjangConsulting/amoo-ai` then `codex plugin add amoo@amoo`; for the subagents, also run `amoo agent install --user --client codex` |
| Gemini CLI | `gemini extensions link "$(brew --prefix amoo)/share/amoo/plugins/amoo"` (it follows `brew upgrade`) |
| Cursor, OpenCode, anything else | `amoo agent install --user --client cursor` (or `opencode`, …) |
| Any Agent Skills host | `npx skills add ArjangConsulting/amoo-ai --skill driving-amoo` (skills only) |

amoo no longer runs an MCP server. If you registered one (`install-mcp.sh`, `claude mcp add`, a plugin
from an older release), remove that entry: `amoo mcp serve` now only prints how to use the CLI.

In Claude Code, the optional **`amoo-live`** mod (`claude plugin install amoo-live@amoo`) adds a
live pane while an agent drives a device. It shows a mirror of the device (in Ghostty and kitty),
per-session actions and progress, pause/resume/retry controls, recording health, ended-session
artifacts, and toasts on failed assertions. It is experimental
and Claude-only; see [amoo-live](docs/amoo-live.md).

Run `amoo init` in a terminal for guided device setup. It prepares independent controlled simulators
and emulators without asking for an app build, and offers to set up the amoo subagents and skills
for your AI clients (Claude Code, Cursor, Codex, Copilot, Gemini, OpenCode). Agents and CI pass flags
instead, for example `amoo init --platform ios --device <phone> --device <tablet> --out <manifest>
--json`. An explicit `--app <absolute-build-path> --app-id <id>` optionally installs an existing
artifact during setup. See [initialization and manifest usage](docs/init.md), including the AI
client step, validation and cleanup.

To install without a marketplace, use `amoo agent install`. It writes the subagents in each
client's native format, plus the skills they rely on. Guided installs choose a scope first, skip the
client picker when that scope already has an install, and point to `amoo agent update` when files
need review. New installs preselect detected clients and preview the files before writing.
`--client`, `--json` or `--non-interactive` skip the questions, so scripts behave as before.

```bash
amoo agent install
amoo agent install --user
amoo agent install --target . --client claude
amoo agent install --dry-run --json
amoo agent install --binary /absolute/path/to/amoo --client codex
amoo agent status --target .
amoo agent update --target . --dry-run
amoo agent update --target .
```

Installs write `.amoo-install.json` in the scope root (repository or home directory). Commit it with
project agent files: its per-file hashes distinguish untouched older files from local edits.
`agent status` inspects this directory and your home directory by default; `--target`, `--user`,
and `--client` narrow the check. It reports `current`, `missing`, `outdated`, `edited`, or
`unrecorded` and exits 1 for any drift. `--json` provides the file states for CI. For project
installs, which are committed and shared, the paragraph pinning one machine's executable is not
compared, so a teammate's or CI runner's different amoo path is not reported as drift.

`agent update` replaces outdated and missing files and refreshes the stamp. It preserves edited
files and differing legacy files without an install hash. Use `--force` to replace them; a terminal
asks once before replacing unrecorded files. `--non-interactive` and `--json` never ask, and
`--dry-run` writes nothing. Updating also refreshes the executable path pinned into the agents,
including changed Homebrew Cellar paths.

To customise an installed agent, write its local rules to `~/.config/amoo/agents/<agent-name>.md`
(for example `amoo.md`) instead of editing the generated file. Every rendered agent reads that file
before setup, and `install` and `update` never write it, so the rules survive updates. Use it to
narrow routing, pin an executable or add standing checks; it cannot loosen the agent's hard rules
or change its report contract. Repository conventions still belong in the repository's `amoo.md`.

Installed agents pin the resolved absolute executable path; shell aliases do not apply. To leave one
client's agent out, for example a project Claude `amoo` agent that would shadow your own user-wide one,
pass `--skip claude:amoo`; it is recorded, so later updates keep leaving it out. Validate delegated results with `amoo agent validate-report --report <report.json>
--run-id <UUID> --checks <caller-check-ids>`. A pass requires all requested assertions evaluated and
passed, complete coverage and resolved cleanup. Detailed evidence stays in local referenced files.

**Model cost.** The agents pin no model. Ask your main agent to delegate device checks on the cheapest
model that can run them, once, in your global instructions (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or Cursor's User Rules):
it then picks per spawn (Claude Code's Agent `model` parameter; Codex's spawn model and effort; the model
Cursor's parent names when it launches a subagent), and the
choice overrides the agent file. To pin a model yourself instead, add `model:` to the Claude agent
file or `model` / `model_reasoning_effort` to the Codex one; `amoo agent update` keeps such edits.

The agents drive devices through `amoo device … --json` and `amoo flow`, so your main session never
loads a tool catalog. Existing files that differ are kept unless you pass `--force`.

For repositories checking in installed agents and skills, pin the Amoo version in CI and check
for drift without writing files:

```bash
python3 .agents/skills/driving-amoo/scripts/check-install.py --client opencode --target .
```

The helper runs `amoo agent install --dry-run --json` and fails for any action other than
`unchanged`, including missing files and preserved local edits. Use `--amoo /absolute/path/to/amoo`
to select the pinned CLI and `--binary /absolute/path/to/amoo` when the installed agents pin a
different executable. For Claude installs the helper lives under `.claude/skills/` instead.
`amoo agent status --target . --client opencode` is the richer successor to this helper.
Refresh with `amoo agent update --target . --client opencode`, review any preserved files, then rerun
the check. Upstream CI verifies a fresh installation round trip for all clients; consumer repos
must run this check against their own checked-in copies to detect drift.

## Build from Source (Contributors)

From an amoo checkout, use Swift 6.2 or newer (see `Package.swift`):

```bash
swift build
swift run amoo preflight --platform ios
make test
make lint
```

The user guides use `amoo` for the installed CLI. When developing from this checkout, substitute
`swift run amoo` or the absolute path to `.build/debug/amoo`.

To pin your user-wide subagents to your local debug build:

```bash
.build/debug/amoo agent install --user --client codex --binary "$PWD/.build/debug/amoo"
```

Repository end-to-end checks require a checkout and the platform tooling:

```bash
scripts/run-e2e-ios.sh
scripts/run-e2e-android.sh
```

## Documentation

- [Support and qualification](docs/support-matrix.md) — platform boundaries, CI and hardware qualification
- [Current architecture](docs/current-architecture.md) — runtime ownership and data flow
- [Accessibility and VoiceOver plan](docs/accessibility-and-voiceover.md) — current evidence limits, public platform APIs, and phased implementation

- [Prerequisites](docs/prerequisites.md) — external tooling, install steps, `make` targets
- [Physical iOS Devices](docs/physical-ios-devices.md) — `iproxy`, pairing, provisioning, current constraints
- [macOS](docs/macos.md) — driving apps on this Mac's desktop (experimental): setup, geometry, limits
- [Device tools](docs/device-tools.md) — what `amoo device` and `amoo flow` do, tool by tool
- [Telemetry](docs/telemetry.md) — local OpenTelemetry traces (on by default, `AMOO_TELEMETRY_LOCAL=0` to turn off), OTLP export, `amoo usage report`
- [Amoo Studio](https://github.com/maniramezan/amoo-studio) — Compose desktop client
- [Studio protocol](docs/studio.md) — Swift service and GUI integration boundary
- [iOS E2E Runbook](docs/e2e-ios.md) — full workflow and troubleshooting
- [Command Contract Guide](docs/command-contract.md) — contributor checklist for coverage
- [API Documentation (DocC)](docs/documentation.md) — generating and browsing the DocC site
- [Homebrew release checklist](docs/homebrew.md) — tap setup and release checklist (maintainer-only)
- [Product/spec context](Instruction.md)
- [System design and module boundaries](Architecture.md)

Generated API reference is published from `main` to
[GitHub Pages](https://arjangconsulting.github.io/amoo-ai/).
