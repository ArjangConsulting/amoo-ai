# iOS E2E Runbook

This document explains how to run the repo-root iOS end-to-end flow, what the helper script does, and how to debug the common failure modes.

## What This Runs

The repo-root iOS e2e entrypoint is:

- [scripts/run-e2e.sh](../scripts/run-e2e.sh)

That script:

1. selects an iOS simulator
2. optionally builds the iOS companion test bundle
3. launches the XCUITest-based companion server
4. waits for the gRPC port on `127.0.0.1:22087`
5. runs [CompanionE2ETests.swift](../Tests/IntegrationTests/CompanionE2ETests.swift)

The integration tests then talk to:

- the companion over `127.0.0.1:22087`
- the selected simulator through `simctl`

## Prerequisites

- Xcode installed and usable from the command line
- an iOS simulator runtime installed
- `xcodegen` available if you want the script to rebuild the companion
- a booted iOS simulator, unless you pass a specific simulator and boot it yourself first

Useful checks:

```bash
xcodebuild -version
xcrun simctl list devices available
bash scripts/run-e2e.sh --help
```

## Fastest Path

Open Simulator.app, boot a simulator, then run:

```bash
scripts/run-e2e.sh --skip-build
```

If build products are stale or missing, run without `--skip-build`:

```bash
scripts/run-e2e.sh
```

## Selecting a Device

### Default behavior

If you run:

```bash
scripts/run-e2e.sh --skip-build
```

the script looks for booted iOS simulators.

- If exactly one booted simulator exists, it uses it.
- If multiple booted simulators exist, it prompts you to choose one when running interactively.
- If none are booted, it fails early and tells you how to boot one.

### Explicit device selection

You can provide a simulator name:

```bash
scripts/run-e2e.sh --skip-build --device "iPhone 17 Pro"
```

or a simulator UDID:

```bash
scripts/run-e2e.sh --skip-build --device 3BE7B404-5A28-48CD-B827-8CBCF4B2FF73
```

If the name matches multiple simulators, the script prompts you to choose one.

Example prompt:

```text
[e2e] Multiple matching targets for 'iPhone 17 Pro' were found. Choose one:
  1) iPhone 17 Pro [iOS 26.2] Booted (3BE7B404-5A28-48CD-B827-8CBCF4B2FF73)
  2) iPhone 17 Pro [iOS 26.4] Shutdown (7C01908A-3F5B-4B20-9996-ABAC72D7188F)
[e2e] Choose a target [1-2]:
```

## What the Script Prints

The script is intentionally verbose. Typical output includes:

- selected simulator
- whether build is skipped
- which `.xctestrun` file is used
- when the companion starts listening
- when integration tests start
- pass/fail summary

That output is the first place to look before opening Xcode logs.

## Booting a Simulator

If no booted simulator is available, the script now fails early and tells you how to start one.

Manual flow:

```bash
open -a Simulator
xcrun simctl list devices available
xcrun simctl boot "<simulator-udid>"
xcrun simctl bootstatus "<simulator-udid>"
scripts/run-e2e.sh --skip-build
```

## Physical Devices

The script detects connected iPhones and iPads, but this repo-root e2e flow is still simulator-only.

Why:

- the integration tests connect to `127.0.0.1:22087`
- the iOS driver still uses `simctl` for host-side actions

So today the script will report physical devices and stop instead of pretending the flow works on them.

If you want true physical-device e2e support, the codebase needs:

- a non-localhost companion transport strategy
- host-side iOS control that uses `devicectl` instead of simulator-only `simctl`

## Useful Commands

Validate the script syntax:

```bash
bash -n scripts/run-e2e.sh
```

Show help:

```bash
bash scripts/run-e2e.sh --help
```

Run the protocol-level test target:

```bash
swift test --filter CompanionProtocolTests
```

Run integration tests directly:

```bash
swift test --filter IntegrationTests
```

Note: running `IntegrationTests` directly without the companion already up will skip the tests. The intended entrypoint is `scripts/run-e2e.sh`.

## Common Failures

### No booted simulator

Symptom:

```text
[e2e] WARNING: No booted iOS simulator is available for this repo-root e2e flow.
```

Fix:

- boot a simulator in Simulator.app
- or boot one explicitly with `xcrun simctl boot`

### Multiple matching simulators in CI or non-interactive shells

Symptom:

```text
[e2e] ERROR: Multiple matching targets were found. Re-run with --device <udid|name>.
```

Fix:

- pass a unique simulator UDID with `--device`

### Companion never becomes reachable

Symptom:

```text
[e2e] ERROR: Companion did not start within 30s.
```

Checks:

- verify the selected simulator actually booted
- verify the companion XCUITest launched
- rerun without `--skip-build` if build artifacts may be stale

### Integration tests skip instead of run

Symptom from [CompanionE2ETests.swift](../Tests/IntegrationTests/CompanionE2ETests.swift):

```text
Companion not running on port 22087. Run via scripts/run-e2e.sh
```

Fix:

- use `scripts/run-e2e.sh` rather than invoking the integration test bundle directly

## Relevant Files

- entrypoint: [scripts/run-e2e.sh](../scripts/run-e2e.sh)
- integration tests: [Tests/IntegrationTests/CompanionE2ETests.swift](../Tests/IntegrationTests/CompanionE2ETests.swift)
- companion test host: [CompanionApps/iOS/Sources/CompanionRunner.swift](../CompanionApps/iOS/Sources/CompanionRunner.swift)
- architecture: [Architecture.md](../Architecture.md)
