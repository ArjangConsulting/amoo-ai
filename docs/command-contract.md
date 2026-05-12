# Command Contract Guide

This repo now treats public commands as a release contract.

## What Is Covered

- MCP tools are declared in `Sources/MCPServer/Tools/*`.
- The shared command inventory lives in `Sources/CommandContract/CommandCoverageMatrix.swift`.
- Every public tool must have:
  - a coverage-matrix entry
  - a deterministic or AI classification
  - a release tier
  - a fixture screen
  - an expected assertion

## Naming Rules

- AI-facing tools must use the `ai_*` prefix.
- Current canonical AI tools are:
  - `ai_describe_screen`
  - `ai_suggest_actions`
  - `ai_suggest_actions_json`
  - `ai_find_by_description`

## Blocking vs Informational

- Blocking release coverage is deterministic command behavior on the repo-owned fixture apps.
- AI flows are informational by default and run in the smoke lane.
- Proto-only or unimplemented commands must stay hidden from the public tool catalog until they are supported end-to-end.

## Contributor Checklist

When adding a new public command:

1. Add the tool definition and executor routing.
2. Add a `CommandCoverageMatrix` entry.
3. Add or reuse a fixture screen/assertion path.
4. Add at least one regression or e2e assertion.
5. If the command is AI-related, use the `ai_*` prefix.

## Entry Points

- iOS: `bash scripts/run-e2e-ios.sh`
- Android: `bash scripts/run-e2e-android.sh`
- Both: `bash scripts/run-e2e-all.sh`
