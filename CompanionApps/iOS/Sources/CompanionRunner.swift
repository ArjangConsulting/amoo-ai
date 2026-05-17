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
        let app = XCUIApplication()
        app.launch()

        let bridge = XCUITestBridge(app: app)
        let port = Self.portFromEnvironment() ?? Self.defaultPort
        let server = CompanionServer(bridge: bridge, port: port)

        // Run the server — this blocks until the host terminates the test.
        try await server.run()
    }

    private static func portFromEnvironment() -> Int? {
        ProcessInfo.processInfo.environment["COMPANION_PORT"].flatMap(Int.init)
    }
}
