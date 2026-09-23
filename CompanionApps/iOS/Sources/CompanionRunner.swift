import XCTest

/// XCUITest entry point for the iOS companion app.
///
/// This test case starts the gRPC companion server and runs it indefinitely,
/// keeping the companion alive to accept commands from the host driver.
///
/// Host driver lifecycle:
/// 1. Build and install the companion XCUITest bundle
/// 2. Run this test via `xcodebuild test-without-building`
/// 3. Send gRPC commands to port 22087
/// 4. Terminate the test when done
final class CompanionRunner: XCTestCase {
    private static let defaultPort = 22087

    /// Disable the default test execution time limit so the companion server
    /// stays alive indefinitely until the host explicitly terminates it.
    override var executionTimeAllowance: TimeInterval {
        get { 86400 } // 24 hours
        set { _ = newValue }
    }

    /// The companion is a server hosted in a test, not a test: an issue XCTest records while
    /// serving one command — a query against an app that just went away — must not end the run
    /// and take the server down for every later command. Log it and keep serving.
    override func record(_ issue: XCTIssue) {
        print("[CompanionRunner] Ignoring XCTest issue: \(issue.compactDescription)")
    }

    @MainActor
    func testRunCompanion() async throws {
        // The host app is not launched. The server runs in this UI-test runner process, which
        // exists without it, and launching it cost ~5s of every companion start (terminate the
        // previous instance, set up its automation session, wait for idle). It is still named, so
        // `XCUITestBridge` can exclude it: XCUITest activates whatever app it delivers an
        // interaction to, and routing through this one would foreground the fixture.
        continueAfterFailure = true
        let app = XCUIApplication()

        let targetBundleID = Self.targetAppFromEnvironment()
        if let targetBundleID {
            // `activate()`, not `launch()`: the session already installed and started the app
            // under test, and relaunching would throw away the state being tested.
            XCUIApplication(bundleIdentifier: targetBundleID).activate()
        }

        let bridge = XCUITestBridge(app: app, targetBundleID: targetBundleID)
        let port = Self.portFromEnvironment() ?? Self.defaultPort
        let server = CompanionServer(bridge: bridge, port: port)

        // Run the server — this blocks until the host terminates the test.
        try await server.run()
    }

    private static func portFromEnvironment() -> Int? {
        ProcessInfo.processInfo.environment["COMPANION_PORT"].flatMap(Int.init)
    }

    /// Bundle ID of the app under test, supplied by the host when a session names one.
    private static func targetAppFromEnvironment() -> String? {
        ProcessInfo.processInfo.environment["COMPANION_TARGET_APP"].flatMap {
            $0.isEmpty ? nil : $0
        }
    }
}
