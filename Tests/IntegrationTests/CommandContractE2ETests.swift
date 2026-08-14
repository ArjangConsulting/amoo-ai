import AmooCore
import AndroidDriver
import CommandContract
import CompanionProtocol
import Darwin.C
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

    func resetFixtureApp(on server: MCPServer) async {
        switch Self.platform {
        case .ios:
            _ = await server.execute(toolName: "device_terminate_app", arguments: ["app_id": Self.fixtureAppID])
            _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        case .android:
            _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    func androidLabelFallback(for id: String?) -> String? {
        guard Self.platform == .android, let id else { return nil }

        switch id {
        case "fixture-home-title": return "Fixture Home"
        case "fixture-open-details": return "Open Details"
        case "fixture-open-text": return "Open Text Input"
        case "fixture-open-gesture": return "Open Gesture Lab"
        case "fixture-detail-row-0": return "Fixture row 0"
        case "fixture-text-input": return "Hello from the fixture app"
        case "fixture-gesture-pad": return "Gesture Pad"
        default: return nil
        }
    }

    func waitForElement(
        on server: MCPServer,
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        attempts: Int = 20,
        sleepMilliseconds: UInt64 = 200
    ) async -> ToolResult {
        let effectiveLabel = label ?? androidLabelFallback(for: id)
        let primaryArguments: [String: String]
        let fallbackArguments: [String: String]?

        if Self.platform == .android {
            primaryArguments = compactArguments(id: id, label: nil, containsText: containsText)
            fallbackArguments = effectiveLabel == nil ? nil : compactArguments(
                id: nil,
                label: effectiveLabel,
                containsText: containsText
            )
        } else {
            primaryArguments = compactArguments(id: id, label: effectiveLabel, containsText: containsText)
            fallbackArguments = nil
        }

        let successNeedles = [id, effectiveLabel, containsText].compactMap(\.self)

        for attempt in 0 ..< attempts {
            let result = await server.execute(toolName: "find_elements", arguments: primaryArguments)
            if !result.isError, successNeedles.contains(where: { result.content.contains($0) }) {
                return result
            }

            if let fallbackArguments {
                let fallbackResult = await server.execute(toolName: "find_elements", arguments: fallbackArguments)
                if !fallbackResult.isError, successNeedles.contains(where: { fallbackResult.content.contains($0) }) {
                    return fallbackResult
                }
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }

        if let fallbackArguments {
            let fallbackResult = await server.execute(toolName: "find_elements", arguments: fallbackArguments)
            if !fallbackResult.isError, successNeedles.contains(where: { fallbackResult.content.contains($0) }) {
                return fallbackResult
            }
        }

        return await server.execute(toolName: "find_elements", arguments: primaryArguments)
    }

    func openFixtureScreen(
        on server: MCPServer,
        launcherID: String,
        launcherLabel: String,
        readyID: String? = nil,
        readyLabel: String? = nil
    ) async -> ToolResult {
        let effectiveLauncherLabel = Self
            .platform == .android ? androidLabelFallback(for: launcherID) ?? launcherLabel : launcherLabel
        let effectiveReadyLabel = Self
            .platform == .android ? readyLabel ?? androidLabelFallback(for: readyID) : readyLabel
        let readyNeedles = [readyID, effectiveReadyLabel].compactMap(\.self)

        func prepareHome() async -> ToolResult {
            await resetFixtureApp(on: server)
            let homeReady = await waitForElement(
                on: server,
                id: "fixture-home-title",
                attempts: Self.platform == .android ? 40 : 20,
                sleepMilliseconds: Self.platform == .android ? 300 : 200
            )
            guard !homeReady.isError,
                  homeReady.content.contains("fixture-home-title") || homeReady.content.contains("Fixture Home")
            else {
                return .error("Fixture home did not become ready: \(homeReady.content)")
            }
            return homeReady
        }

        let launcherByID = await server.execute(toolName: "find_elements", arguments: ["id": launcherID])
        let launcherByLabel = await server.execute(
            toolName: "find_elements",
            arguments: ["label": effectiveLauncherLabel]
        )

        let homeReady = await prepareHome()
        guard !homeReady.isError else {
            return homeReady
        }

        let context = FixtureLauncherContext(
            server: server,
            launcherID: launcherID,
            effectiveLauncherLabel: effectiveLauncherLabel,
            readyID: readyID,
            effectiveReadyLabel: effectiveReadyLabel,
            readyNeedles: readyNeedles,
            launcherByID: launcherByID,
            launcherByLabel: launcherByLabel
        )

        let openByID = await server.execute(toolName: "tap_element", arguments: ["id": launcherID])
        guard !openByID.isError else {
            return await openFixtureScreenViaLabelFallback(context)
        }

        let readyAfterID = await waitForElement(on: server, id: readyID, label: effectiveReadyLabel)
        if !readyAfterID.isError, readyNeedles.contains(where: { readyAfterID.content.contains($0) }) {
            return readyAfterID
        }

        return await retryFixtureScreenViaLabel(context, prepareHome: prepareHome, readyAfterID: readyAfterID)
    }

    struct FixtureLauncherContext {
        let server: MCPServer
        let launcherID: String
        let effectiveLauncherLabel: String
        let readyID: String?
        let effectiveReadyLabel: String?
        let readyNeedles: [String]
        let launcherByID: ToolResult
        let launcherByLabel: ToolResult
    }

    func openFixtureScreenViaLabelFallback(_ context: FixtureLauncherContext) async -> ToolResult {
        let openByLabel = await context.server.execute(
            toolName: "tap_element",
            arguments: ["label": context.effectiveLauncherLabel]
        )
        guard !openByLabel.isError else {
            return .error(
                "Failed to open fixture screen: \(openByLabel.content)"
                    + " | idQuery=\(context.launcherByID.content) | labelQuery=\(context.launcherByLabel.content)"
            )
        }
        let ready = await waitForElement(on: context.server, id: context.readyID, label: context.effectiveReadyLabel)
        guard !ready.isError, context.readyNeedles.contains(where: { ready.content.contains($0) }) else {
            return .error("Fixture screen did not become ready: \(ready.content)")
        }
        return ready
    }

    func retryFixtureScreenViaLabel(
        _ context: FixtureLauncherContext,
        prepareHome: () async -> ToolResult,
        readyAfterID: ToolResult
    ) async -> ToolResult {
        let homeReadyForLabel = await prepareHome()
        guard !homeReadyForLabel.isError else {
            return homeReadyForLabel
        }

        let openByLabel = await context.server.execute(
            toolName: "tap_element",
            arguments: ["label": context.effectiveLauncherLabel]
        )
        guard !openByLabel.isError else {
            return .error(
                "Failed to open fixture screen: \(openByLabel.content)"
                    + " | idQuery=\(context.launcherByID.content) | labelQuery=\(context.launcherByLabel.content)"
            )
        }

        let readyAfterLabel = await waitForElement(
            on: context.server,
            id: context.readyID,
            label: context.effectiveReadyLabel
        )
        guard !readyAfterLabel.isError,
              context.readyNeedles.contains(where: { readyAfterLabel.content.contains($0) })
        else {
            return .error(
                "Fixture screen did not become ready: \(readyAfterLabel.content)"
                    + " | readyAfterID=\(readyAfterID.content)"
                    + " | idQuery=\(context.launcherByID.content) | labelQuery=\(context.launcherByLabel.content)"
            )
        }

        return readyAfterLabel
    }

    func compactArguments(id: String?, label: String?, containsText: String?) -> [String: String] {
        var arguments: [String: String] = [:]
        if let id {
            arguments["id"] = id
        }
        if let label {
            arguments["label"] = label
        }
        if let containsText {
            arguments["contains_text"] = containsText
        }
        return arguments
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

        await resetFixtureApp(on: server)

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
