# Support and qualification

The shared protocols express intended parity. Platform capabilities and runtime errors determine
what a particular device supports; interface availability alone is not evidence of qualification.

| Area | iOS simulator | Physical iOS | Android emulator | Physical Android |
| --- | --- | --- | --- | --- |
| UI queries and gestures | XCUITest companion | Signed XCUITest runner | UIAutomator companion | UIAutomator companion |
| Lifecycle/install | simctl | devicectl, pairing and signing | adb | adb authorization |
| Host connection | loopback | iproxy USB tunnel | adb forward | adb forward |
| CI smoke | Added, requires successful hosted run | Opt-in dedicated runner | Added, requires successful hosted run | Opt-in dedicated runner |
| OS/device qualification | No new qualification claimed by this change | No new qualification claimed | No new qualification claimed | No new qualification claimed |

macOS 15+ and a compatible Xcode are required for iOS. The package requires Swift tools 6.2+.
Android companions require the SDK and JDK 17–26 for the checked-in AGP/Gradle stack. Generic Linux
Swift tests do not prove iOS behavior. WebView inspection, permissions, system UI, keyboard state,
and gestures vary by OS and application framework; check advertised capabilities and assert the
intended outcome rather than assuming parity from a tool name.

## CI and hardware setup

`companions.yml` builds both companions and runs a small strict smoke suite. With
`AMOO_E2E_STRICT=1`, missing companions and failed setup queries fail the job instead of becoming
skipped tests. Platform-specific unsupported scenarios can still skip. `make companion-ios-build`
regenerates protos/project inputs, and shell pipeline failures propagate to Make.

`hardware-qualification.yml` is scheduled weekly and manually runnable. Enable it only after
registering a dedicated runner with `self-hosted`, `macOS`, and `amoo-hardware` labels. Set repository
variables `AMOO_ENABLE_HARDWARE_TESTS=true`, `AMOO_IOS_DEVICE_ID`, and `AMOO_ANDROID_DEVICE_ID`.
Install required tools, authorize USB devices, and provision/sign/install the iOS test runner first.
The job runs serially across the platform matrix and uploads a test log. Devices must be dedicated
test hardware with fixture data. A configured workflow is not a successful qualification result.

For each qualified release, retain the commit, Xcode/Swift/JDK versions, companion build identity,
device model, OS version, transport, scenario list, failures/skips and logs. Do not list a device/OS
combination as qualified until that run succeeds. Include secure text replacement, repeated labels,
background/foreground transitions, offline recovery and WebViews in a broader manual matrix.

## Current boundaries

Companions bind IPv4 loopback. Remote network service, authentication and TLS are not implemented.
Process-local leases prevent overlapping managed sessions in one server, not separate clients or
server processes. Recorded artifacts redact known textual secrets; screenshots are raw visual
evidence. Audits inspect current-screen evidence and do not certify manifests, signing, production
build settings or URL validation. See [MCP usage](mcp-server.md) for failure recovery and token costs.
