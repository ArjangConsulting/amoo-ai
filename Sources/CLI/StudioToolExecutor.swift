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
actor CLIStudioToolExecutor: StudioToolExecuting {
    private struct Connection {
        let companion: GRPCCompanionClient
        let executor: DriverToolExecutor
    }

    private let iOSCompanionManager = CompanionManager()
    private let androidCompanionManager = AndroidCompanionManager()
    private var connections: [String: Connection] = [:]

    func execute(
        _ operation: StudioToolOperation,
        deviceId: String,
        platform: String,
        appId: String?
    ) async throws -> StudioToolExecutionResult {
        let connection = try await connection(deviceId: deviceId, platform: platform, appId: appId)
        let result = await connection.executor.execute(toolName: operation.tool, arguments: operation.arguments)
        guard !result.isError else { throw StudioToolExecutorError.toolFailed(result.content) }

        var artifacts: [String] = []
        if let image = result.image {
            let url = try artifactURL(operationID: operation.id, mimeType: image.mimeType)
            try image.data.write(to: url, options: .atomic)
            artifacts.append(url.path)
        }
        return .init(output: result.content, artifacts: artifacts)
    }

    private func connection(deviceId: String, platform: String, appId: String?) async throws -> Connection {
        let normalizedPlatform = platform.lowercased()
        let key = "\(normalizedPlatform):\(deviceId)"
        if let existing = connections[key] {
            return existing
        }

        let companion: GRPCCompanionClient
        let driver: any PlatformDriver
        switch normalizedPlatform {
        case "ios":
            let port = 22087
            try await iOSCompanionManager.ensureRunning(config: .init(
                port: port,
                deviceUDID: deviceId,
                targetAppID: appId
            ))
            companion = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: port))
            driver = await makeIOSDriver(companion: companion, deviceID: deviceId)
        case "android":
            let port = 22088
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
