import AmooCore
import Foundation

/// Owns active sessions and bootstraps new ones. Created once per MCP server.
public actor SessionManager {
    private let bootstrapper: any SessionBootstrapper
    private let idGenerator: @Sendable () -> String
    private let store: (any SessionStore)?
    private var sessions: [String: TestSession] = [:]
    /// Reports loaded from disk for sessions this process never held live — the
    /// path that lets history outlive an `amoo mcp serve` restart.
    private var closedReports: [String: SessionReport] = [:]

    public init(
        bootstrapper: any SessionBootstrapper,
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        store: (any SessionStore)? = nil
    ) {
        self.bootstrapper = bootstrapper
        self.idGenerator = idGenerator
        self.store = store
    }

    public func startSession(
        appID: String,
        platform: Platform,
        deviceHint: String? = nil,
        buildPath: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> TestSession {
        let bootstrap = try await bootstrapper.bootstrap(
            SessionBootstrapRequest(
                appID: appID,
                platform: platform,
                deviceHint: deviceHint,
                buildPath: buildPath,
                arguments: arguments,
                environment: environment
            )
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
        await persist(id)
    }

    public func allSessions() -> [TestSession] {
        Array(sessions.values)
    }

    /// Flush a live session's current history to the store. Called write-through
    /// after every recorded action and on `endSession`, so a hard crash loses at
    /// most the action in flight.
    public func persist(_ id: String) async {
        guard let store, let session = sessions[id] else { return }
        await store.save(SessionReport.make(from: session))
    }

    /// The on-disk directory backing a session, or `nil` when no store is
    /// configured. The MCP layer writes `plan.json` / `flow.json` here.
    public func sessionDirectory(for id: String) -> URL? {
        store?.directory(for: id)
    }

    /// A report for `id` from the freshest source: a live session, then a
    /// disk report cached this process, then the store.
    public func report(for id: String) async -> SessionReport? {
        if let session = sessions[id] {
            return await SessionReport.make(from: session)
        }
        if let cached = closedReports[id] {
            return cached
        }
        if let store, let loaded = await store.loadReport(sessionID: id) {
            closedReports[id] = loaded
            return loaded
        }
        return nil
    }

    /// Every known session as a report — live sessions merged over disk reports,
    /// live winning on id collision. Sorted by start time.
    public func allReports() async -> [SessionReport] {
        var byID: [String: SessionReport] = [:]
        if let store {
            for report in await store.loadAllReports() {
                byID[report.sessionID] = report
            }
        }
        for (id, report) in closedReports {
            byID[id] = report
        }
        for (id, session) in sessions {
            byID[id] = await SessionReport.make(from: session)
        }
        return byID.values.sorted { $0.startedAt < $1.startedAt }
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
