@AGENTS.md

# Claude Code — project-specific notes

`AGENTS.md` (imported above) is the main instruction set. This file holds only what is specific to
running Claude Code in this repo.

- **Skills**: the user-facing amoo plugin lives in `plugins/amoo/` — the `amoo` and
  `device-verifier` subagents plus the `driving-amoo` (drive a device / record a session that
  generates a good test) and `device-verifier` skills. `skills/` holds contributor skills
  (`ios-accessibility`, `ios-simulator`, `android-*`, …). Prefer invoking the relevant skill over
  re-deriving its workflow. After editing `plugins/amoo/agents/*.md`, run `make plugin`. `MCPInstructionsAlignmentTests` keeps the MCP `initialize`
  instructions and `plugins/amoo/skills/driving-amoo/SKILL.md` in sync — update both together.
- **Auto-memory**: recurring, hard-won facts about this repo are in the project memory index
  (`MEMORY.md`). Check it before deep dives; add to it when you learn something non-obvious that
  isn't already captured by the code, `AGENTS.md`, or `Architecture.md`.
- **Global preferences**: `~/.claude/CLAUDE.md` carries the user's cross-project standards
  (logging patterns, "no `CHANGELOG.md`", "confirm conventions first", response style). They apply
  here too; where this repo's practice differs (e.g. tests stay on XCTest), the repo wins.
- **Lint before you hand back**: run `make lint` (or `make check`) after the final edit — see the
  "Lint: recurring fixes" table in `AGENTS.md` for the rules that bite most often.
