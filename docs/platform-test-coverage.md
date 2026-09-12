# Platform test coverage

The host suite exercises platform drivers through injected companion clients and process runners.
These tests run without devices. Live tests are a separate layer: a passing mock or a skipped E2E
case does not establish that a simulator, emulator, or physical device works.

| Target | Automated coverage | Live validation |
| --- | --- | --- |
| iOS simulator | `IOSDriverTests`, `ProcessRunnerTests`, shared MCP tests | Companion workflow builds with Xcode and runs `CommandContractE2ETests` on a simulator |
| Physical iOS | `PhysicalDeviceHostBackendTests`, `DeviceCtlRunnerTests`, `DeviceCtlTimeoutTests`, USB tunnel tests | Requires a paired device and signed companion; hosted CI does not supply hardware |
| Android emulator and device | `AndroidDriverTests`, ADB/process-runner tests, shared MCP tests | Companion workflow runs the command-contract suite on an emulator; `scripts/run-e2e-android.sh --device <serial>` also selects connected hardware |
| Compose fixture | `FixtureContractTest` and `ComposeFixtureFlowTest` instrumentation tests | `make sample-app-compose-test`, also run by the Android companion workflow |
| macOS host | XCTest/Swift Testing suite and LLVM coverage gate | `.github/workflows/ci.yml` |
| Linux host | Swift build and tests in `swift:6.3-noble`; orchestration tests | `make verify-linux`; CI excludes `IntegrationTests` and `CLIQualityCoverageTests` as documented in the workflow |

## Regression checks

- Ambiguous selectors: empty/single matches, candidate limits, missing geometry, hit-point
  precedence, frame-center fallback, and omission of private element values.
- Physical iOS: read-only queries carry a timeout; timeouts propagate; installing an app does not
  use the short query timeout. Lifecycle tests verify the physical-device backend and ensure a
  reinstall does not introduce an uninstall.
- Android orchestration: normal runs build the separate fixture, reuse mode still installs it,
  missing artifacts fail before instrumentation, and test failure status survives cleanup and
  log collection. These Python tests run on both host CI jobs.
- Shared live contract: sessions, home queries, scrolling to a visible final row, editing and
  clearing text, gestures, home/relaunch, and deep links/screenshots. iOS-only hierarchy and
  unnamed-control tests retain their explicit Android skips. The unfinished assistant-command
  test retains its explicit skip.
- Compose fixture: navigation to/from details, scrolling to the tail, disabled controls, text echo
  and clearing, tap-count changes, and deep links resolving to the fixture package.

## Commands

```bash
make lint
swift test
make coverage
python3 -m unittest discover -s scripts/tests -v
make verify-linux
make companion-ios-build
make companion-android-build sample-app-compose-build
make sample-app-compose-test
AMOO_E2E_STRICT=1 AMOO_E2E_FILTER=IntegrationTests.CommandContractE2ETests scripts/run-e2e-ios.sh
AMOO_E2E_STRICT=1 AMOO_E2E_FILTER=IntegrationTests.CommandContractE2ETests scripts/run-e2e-android.sh
```

The Swift coverage gate measures host source lines, not Kotlin or on-device Swift code. Its
existing aggregate minimums remain unchanged: repository 67%, core 70%, driver/protocol group 74%,
CLI 45%. Each mobile driver also has an independent 75% minimum. Missing platform coverage fails
the gate.
Use its per-module output to locate gaps; a combined percentage can conceal a weak platform.
Physical-device validation remains necessary for signing, USB transport, OS integration, and
hardware-specific behavior.
