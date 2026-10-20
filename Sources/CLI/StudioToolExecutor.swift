import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer
import StudioProtocol

enum StudioToolExecutorError: Error, CustomStringConvertible {
    case unsupportedPlatform(String)
    case toolFailed(String)

    var description: String {
        switch self {
        case let .unsupportedPlatform(platform): "Unsupported test platform: \(platform)"
        case let .toolFailed(message): message
        }
    }
}

/// Adapts Studio's typed plan operations to the same verified tool executor used by MCP and flows.
/// Connections are cached for the Studio process lifetime so a plan runs against one persistent
/// companion/driver instead of reconnecting between steps.
actor CLIStudioToolExecutor: StudioToolExecuting, StudioElementSuggesting {
    private struct Connection {
        let companion: GRPCCompanionClient
        let executor: DriverToolExecutor
    }

    private struct CachedElements {
        let capturedAt: ContinuousClock.Instant
        let elements: [StudioElementSuggestion]
    }

    /// Long enough to serve a burst of keystrokes, short enough that an animation settling or a
    /// change made outside Studio is picked up on the next completion.
    private static let elementCacheLifetime: Swift.Duration = .seconds(3)

    private let iOSCompanionManager = CompanionManager()
    private let androidCompanionManager = AndroidCompanionManager()
    private var connections: [String: Connection] = [:]
    private var elementCache: [String: CachedElements] = [:]

    func execute(
        _ operation: StudioToolOperation,
        deviceId: String,
        platform: String,
        appId: String?
    ) async throws -> StudioToolExecutionResult {
        let connection = try await connection(deviceId: deviceId, platform: platform, appId: appId)
        let call = Self.mcpCall(for: operation)
        let result = await connection.executor.execute(toolName: call.tool, arguments: call.arguments)
        guard !result.isError else { throw StudioToolExecutorError.toolFailed(result.content) }

        var artifacts: [String] = []
        if let image = result.image {
            let url = try artifactURL(operationID: operation.id, mimeType: image.mimeType)
            try image.data.write(to: url, options: .atomic)
            artifacts.append(url.path)
        }
        let structured = result.structuredContent.flatMap { value in
            (try? JSONEncoder().encode(value)).flatMap { String(bytes: $0, encoding: .utf8) }
        }
        return .init(output: result.content, artifacts: artifacts, structuredContent: structured)
    }

    /// Translates plan vocabulary the MCP executor does not implement into the MCP tools the
    /// session compiler records them from, so authored plans and the console run the same checks.
    static func mcpCall(for operation: StudioToolOperation) -> (tool: String, arguments: [String: String]) {
        var arguments = operation.arguments
        switch operation.tool {
        case StudioTool.assertNotVisible.rawValue:
            return ("assert_absent", arguments)
        case StudioTool.waitForElement.rawValue:
            return ("assert_visible", arguments)
        case StudioTool.assertText.rawValue:
            // Selector fields are all-must-match, so the expected text constrains the element's label.
            let expected = arguments.removeValue(forKey: PlanArgument.expected.rawValue)
            let hasSelector = arguments[PlanArgument.id.rawValue] != nil || arguments[PlanArgument.label.rawValue] !=
                nil
            if let expected {
                arguments[hasSelector ? PlanArgument.label.rawValue : PlanArgument.containsText.rawValue] = expected
            }
            return ("assert_visible", arguments)
        default:
            return (operation.tool, arguments)
        }
    }

    /// Elements on screen, only from a device whose companion is already connected: completion must
    /// never start a companion, which can take minutes.
    func elements(deviceId: String, platform: String) async throws -> [StudioElementSuggestion] {
        let key = Self.key(deviceId: deviceId, platform: platform)
        if let cached = elementCache[key], ContinuousClock.now - cached.capturedAt < Self.elementCacheLifetime {
            return cached.elements
        }
        guard let connection = connections[key] else { return [] }
        let result = await connection.executor.execute(
            toolName: "find_elements",
            arguments: ["labeled_only": "true", "limit": "500"]
        )
        guard !result.isError else { throw StudioToolExecutorError.toolFailed(result.content) }
        let elements = result.observedElements.map { element in
            StudioElementSuggestion(id: element.id, label: element.label, type: element.elementType)
        }
        elementCache[key] = .init(capturedAt: .now, elements: elements)
        return elements
    }

    func invalidate(deviceId: String) {
        elementCache = elementCache.filter { !$0.key.hasSuffix(":\(deviceId)") }
    }

    private static func key(deviceId: String, platform: String) -> String {
        "\(platform.lowercased()):\(deviceId)"
    }

    private func connection(deviceId: String, platform: String, appId: String?) async throws -> Connection {
        let normalizedPlatform = platform.lowercased()
        let key = Self.key(deviceId: deviceId, platform: platform)
        if let existing = connections[key] {
            return existing
        }

        let companion: GRPCCompanionClient
        let driver: any PlatformDriver
        switch normalizedPlatform {
        case "ios":
            // One port per simulator, so two devices open in Studio do not fight over a shared one.
            let port = IOSCompanionPort.forDevice(deviceId)
            try await iOSCompanionManager.ensureRunning(config: .init(
                port: port,
                deviceUDID: deviceId,
                targetAppID: appId
            ))
            companion = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: port))
            driver = await makeIOSDriver(companion: companion, deviceID: deviceId)
        case "android":
            let port = await androidCompanionManager.companionPort(forSerial: deviceId)
            try await androidCompanionManager.ensureRunning(config: .init(port: port, serial: deviceId))
            companion = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: port))
            driver = AndroidDriver(
                companion: companion,
                inspectionMode: .productionDefault(),
                serial: deviceId
            )
        default:
            throw StudioToolExecutorError.unsupportedPlatform(platform)
        }
        let created = Connection(companion: companion, executor: DriverToolExecutor(driver: driver))
        connections[key] = created
        return created
    }

    private func artifactURL(operationID: String, mimeType: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Amoo/Studio/artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileExtension = mimeType == "image/jpeg" ? "jpg" : "png"
        return root.appending(path: "\(operationID)-\(UUID().uuidString).\(fileExtension)")
    }
}
