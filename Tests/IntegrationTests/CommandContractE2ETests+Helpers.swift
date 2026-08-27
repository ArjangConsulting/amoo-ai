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

extension CommandContractE2ETests {
    func resetFixtureApp(on server: MCPServer) async -> ToolResult {
        _ = await server.execute(toolName: "device_terminate_app", arguments: ["app_id": Self.fixtureAppID])
        let launch = await server.execute(
            toolName: "device_launch_app",
            arguments: ["app_id": Self.fixtureAppID, "timeout_ms": "15000"]
        )
        guard !launch.isError else {
            return .error("Fixture app did not reach the foreground: \(launch.content)")
        }

        let homeReady = await waitForElement(
            on: server,
            id: "fixture-home-title",
            attempts: 50,
            sleepMilliseconds: 200
        )
        guard !homeReady.isError,
              homeReady.content.contains("fixture-home-title") || homeReady.content.contains("Fixture Home")
        else {
            return .error("Fixture home did not become ready after launch: \(homeReady.content)")
        }
        return homeReady
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

        var consecutiveMatches = 0
        var lastMatch: ToolResult?
        for attempt in 0 ..< attempts {
            let result = await server.execute(toolName: "find_elements", arguments: primaryArguments)
            if !result.isError, successNeedles.contains(where: { result.content.contains($0) }) {
                consecutiveMatches += 1
                lastMatch = result
            } else if let fallbackArguments {
                let fallbackResult = await server.execute(toolName: "find_elements", arguments: fallbackArguments)
                if !fallbackResult.isError, successNeedles.contains(where: { fallbackResult.content.contains($0) }) {
                    consecutiveMatches += 1
                    lastMatch = fallbackResult
                } else {
                    consecutiveMatches = 0
                    lastMatch = nil
                }
            } else {
                consecutiveMatches = 0
                lastMatch = nil
            }

            // A single hierarchy read can catch a transient node during activity launch or
            // recomposition. Two consecutive observations prove the screen has actually settled.
            if consecutiveMatches >= 2, let lastMatch {
                return lastMatch
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }

        let primaryResult = await server.execute(toolName: "find_elements", arguments: primaryArguments)
        let fallbackResult: ToolResult? = if let fallbackArguments {
            await server.execute(toolName: "find_elements", arguments: fallbackArguments)
        } else {
            nil
        }
        return .error(
            "Element did not remain visible for two consecutive observations."
                + " primary=\(primaryResult.content)"
                + (fallbackResult.map { " fallback=\($0.content)" } ?? "")
        )
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
}
