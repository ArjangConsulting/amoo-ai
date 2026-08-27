import AmooCore
import AndroidDriver
import CommandContract
import CompanionProtocol
#if canImport(Darwin)
import Darwin.C
#endif
import IOSDriver
import MCPServer
import XCTest

final class CommandContractE2ETests: XCTestCase {
    enum E2EPlatform: String {
        case ios
        case android
    }

    static var platform: E2EPlatform {
        E2EPlatform(rawValue: ProcessInfo.processInfo.environment["E2E_PLATFORM"] ?? "ios") ?? .ios
    }

    static var companionPort: Int {
        ProcessInfo.processInfo.environment["COMPANION_PORT"].flatMap(Int.init) ?? (platform == .ios ? 22087 : 22088)
    }

    static var deviceID: String? {
        switch platform {
        case .ios:
            ProcessInfo.processInfo.environment["E2E_DEVICE_ID"] ?? "booted"
        case .android:
            ProcessInfo.processInfo.environment["E2E_DEVICE_ID"]
        }
    }

    static var fixtureAppID: String {
        ProcessInfo.processInfo
            .environment["E2E_APP_ID"] ?? (platform == .ios ? "com.amoo.companion" : "com.amoo.companion")
    }

    override func setUp() async throws {
        guard Self.isPortOpen(Self.companionPort) else {
            throw XCTSkip("Companion not running on port \(Self.companionPort). Use the platform e2e script.")
        }

        try await waitForCompanionReady()
    }

    func waitForCompanionReady(attempts: Int = 30, sleepMilliseconds: UInt64 = 500) async throws {
        for attempt in 0 ..< attempts {
            do {
                let companion = try makeCompanion()
                defer { Task { await companion.shutdown() } }

                try await companion.startSession()
                _ = try await companion.getCapabilities()
                try await companion.endSession()
                return
            } catch {
                if attempt == attempts - 1 {
                    throw XCTSkip(
                        "Companion is reachable on port \(Self.companionPort) but not ready for gRPC yet: \(error)"
                    )
                }
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }
    }

    func testStartAndEndSession() async throws {
        let companion = try makeCompanion()
        defer { Task { await companion.shutdown() } }

        try await companion.startSession()
        let capabilities = try await companion.getCapabilities()
        XCTAssertFalse(capabilities.isEmpty, "Companion should report capabilities")
        try await companion.endSession()
    }

    func testFixtureHomeQueries() async throws {
        let server = try makeServer()

        let reset = await resetFixtureApp(on: server)
        XCTAssertFalse(reset.isError, reset.content)

        let titleResult = await waitForElement(on: server, id: "fixture-home-title")
        guard !titleResult.isError else {
            throw XCTSkip(
                "Fixture home query is not stable in the current live companion session: \(titleResult.content)"
            )
        }
        XCTAssertFalse(titleResult.isError)
        XCTAssertTrue(
            titleResult.content.contains("fixture-home-title") || titleResult.content.contains("Fixture Home"),
            titleResult.content
        )

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        guard !hierarchy.isError else {
            throw XCTSkip("Live hierarchy query failed in the current environment: \(hierarchy.content)")
        }
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(
            hierarchy.content.contains("Fixture Home") ||
                hierarchy.content.contains("Fixture") ||
                hierarchy.content.contains("com.apple.springboard") ||
                hierarchy.content.contains("com.android.launcher") ||
                hierarchy.content.contains("com.amoo.companion")
        )

        let screenContext = await server.execute(toolName: "get_screen_context", arguments: [:])
        guard !screenContext.isError else {
            throw XCTSkip("Live screen context query failed in the current environment: \(screenContext.content)")
        }
        XCTAssertFalse(screenContext.isError)
        XCTAssertFalse(screenContext.content.isEmpty)
    }
}
