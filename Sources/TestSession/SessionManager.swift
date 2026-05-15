import Foundation
import MobileTestingCore

/// Owns active sessions and bootstraps new ones. Created once per MCP server.
public actor SessionManager: Sendable {
    private let bootstrapper: any SessionBootstrapper
    private let idGenerator: @Sendable () -> String
    private var sessions: [String: TestSession] = [:]

    public init(
        bootstrapper: any SessionBootstrapper,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.bootstrapper = bootstrapper
        self.idGenerator = idGenerator
    }

    public func startSession(
        appID: String,
        platform: Platform,
        deviceHint: String? = nil,
        buildPath: String? = nil
    ) async throws -> TestSession {
        let bootstrap = try await bootstrapper.bootstrap(
            appID: appID,
            platform: platform,
            deviceHint: deviceHint,
            buildPath: buildPath
        )
        let id = idGenerator()
        let session = TestSession(
            id: id,
            appID: appID,
            deviceID: bootstrap.deviceID,
            platform: bootstrap.platform,
            driver: bootstrap.driver,
            cleanup: bootstrap.cleanup
        )
        sessions[id] = session
        return session
    }

    public func session(_ id: String) -> TestSession? {
        sessions[id]
    }

    public func endSession(_ id: String) async throws {
        // Keep the session in the registry so list_sessions / get_session_report
        // can still see its accumulated history after it ends. The session is
        // marked inactive via close(); resolveDriver in the executor falls back
        // to the default driver for inactive sessions.
        guard let session = sessions[id] else {
            throw SessionError.notFound(id)
        }
        await session.close()
    }

    public func allSessions() -> [TestSession] {
        Array(sessions.values)
    }

    public func listAvailableDevices(platform: Platform?) async throws -> [DeviceInfo] {
        try await bootstrapper.listDevices(platform: platform)
    }

    /// Closes every active session. Used during MCP server shutdown.
    public func closeAll() async {
        let active = Array(sessions.values)
        sessions.removeAll()
        for session in active {
            await session.close()
        }
    }
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case let .notFound(id): "Session not found: \(id)"
        }
    }
}
