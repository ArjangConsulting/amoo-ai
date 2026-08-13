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

    @MainActor
    func testRunCompanion() async throws {
        // The host app exists purely to give this test bundle a process to live in. It is never
        // the gesture target: `XCUITestBridge` resolves that per command and deliberately excludes
        // this app, because XCUITest activates whatever app it delivers an interaction to —
        // routing through this one foregrounds the fixture and swallows every tap.
        let app = XCUIApplication()
        app.launch()

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
