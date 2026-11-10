# Distributable plugin (`plugins/amoo`)

The user-facing subagents (`amoo`, `device-verifier`) and skills (`driving-amoo`,
`device-verifier`) live in `plugins/amoo/`, packaged for every client's marketplace: Claude and
Cursor (`.claude-plugin/` / `.cursor-plugin/`), Agent Plugins 1.0 (`plugin.json`, used by Copilot
and Codex), and Gemini (`gemini-extension.json`). The repo-root `.claude-plugin/`,
`.cursor-plugin/` and `.agents/plugins/` hold the marketplace catalogs. `agents/*.md` is the
canonical source and keeps only `name` and `description` in its frontmatter. `amoo agent install`
renders it for each client (`Sources/CLI/AgentRenderer.swift`), and `make plugin` regenerates the
committed `com.github.copilot/agents/*`. `AmooPluginTests` fails on stale or inconsistent files.

The plugin ships the `driving-amoo`, `ios-accessibility`, `android-accessibility`, and
`device-verifier` skills under `plugins/amoo/skills/`; installed copies belong to the consuming
repository or client. Contributor references under `skills/` and global skills such as
`device-interaction` are separate. Load `driving-amoo` for main-context device work; delegate
bounded checks to the `amoo` subagent (a consuming repo may call it `amoo-debug`). `amoo-debug`
is a subagent name, not a skill. `device-verifier` handles built artifacts with checked-in
flows and WebView probes; the generic `amoo` subagent handles bounded device assertions.
Keep discovery, flows needing user decisions, and source edits in the main context. Supply
app_id, build_path, device_hint, and exact launch_env when delegating; enable reset only for a
requested clean store. Consumer CI can check installed copies with the bundled
`driving-amoo/scripts/check-install.py` helper described in README.md.

`plugins/amoo-live` is a separate, Claude Code-only **mod** (a TypeScript hooks module:
`hooks/register.tsx`, state contract `types/index.d.ts`). It mirrors the driven device in a pane via
`amoo device stream` (`Sources/CLI/DeviceStreamCommand.swift`), and it is listed only in
`.claude-plugin/marketplace.json`. Never add a `hooks/` folder to `plugins/amoo`, because Gemini
reads `hooks/hooks.json` there. After editing the mod, run `make mod-check`. See `docs/amoo-live.md`.
