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
    /// Recorded-but-not-yet-written action counts and last flush times, per session.
    private var unflushedActions: [String: Int] = [:]
    private var flushTimers: [String: Task<Void, Never>] = [:]
    private var shuttingDown = false
    private var lastFlush: [String: Date] = [:]
    /// One writer per session coalesces pending flushes before constructing their snapshots.
    private var writers: [String: Task<Void, Never>] = [:]
    private var requestedWrites: [String: UInt64] = [:]
    private var completedWrites: [String: UInt64] = [:]

    /// Per-session codegen intent supplied through the control plane (`start_session` /
    /// `compile_session_to_plan`): a descriptive test name/description and a reference to the
    /// app-owned `StudioTestContext` JSON. Kept here — not in the recorded action history — so
    /// `end_session`'s auto-compile reproduces the same plan an explicit `compile_session_to_plan`
    /// would, without a control-plane call ever becoming a recorded test step.
    private var sessionCodegenIntent: [String: SessionCodegenIntent] = [:]

    /// Flush after this many recorded actions, or this long since the last flush, whichever
    /// comes first. Together they bound both the write amplification and the crash window.
    private static let flushActionThreshold = 10
    private static let flushInterval: TimeInterval = 5

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
        buildMode: SessionBuildMode = .auto,
        arguments: [String] = [],
        environment: [String: String] = [:],
        testName: String? = nil,
        port: Int? = nil
    ) async throws -> TestSession {
        try Task.checkCancellation()
        guard !shuttingDown else { throw SessionError.closed("server") }
        let bootstrap = try await bootstrapper.bootstrap(
            SessionBootstrapRequest(
                appID: appID,
                platform: platform,
                deviceHint: deviceHint,
                buildPath: buildPath,
                buildMode: buildMode,
                arguments: arguments,
                environment: environment,
                port: port
            )
        )
        guard !shuttingDown, !Task.isCancelled else {
            await bootstrap.cleanup()
            if Task.isCancelled {
                throw CancellationError()
            }
            throw SessionError.closed("server")
        }
        let id = idGenerator()
        let session = TestSession(
            id: id,
            appID: appID,
            deviceID: bootstrap.deviceID,
            platform: bootstrap.platform,
            driver: bootstrap.driver,
            launchArguments: arguments,
            launchEnvironment: environment,
            testName: testName,
            appArtifactSHA256: bootstrap.appArtifactSHA256,
            cleanup: bootstrap.cleanup
        )
        sessions[id] = session
        await flush(id)
        return session
    }

    public func session(_ id: String) -> TestSession? {
        sessions[id]
    }

    public func endSession(_ id: String, force: Bool = false) async throws {
        // Keep the session in the registry so list_sessions / get_session_report
        // can still see its accumulated history after it ends. The session is
        // marked inactive via close(); subsequent device operations reject the session.
        guard let session = sessions[id] else {
            throw SessionError.notFound(id)
        }
        await session.close(terminateApp: !force)
        await flush(id)
        await drainPendingWrites()
        await evictClosedSessions()
    }

    private func evictClosedSessions() async {
        guard let store else { return }
        var closed: [TestSession] = []
        for session in sessions.values where await !session.isActive {
            closed.append(session)
        }
        for session in closed.sorted(by: { $0.startedAt > $1.startedAt }).dropFirst(32) {
            guard await store.recordingHealth(sessionID: session.id) == "saved" else { continue }
            sessions.removeValue(forKey: session.id)
            sessionCodegenIntent.removeValue(forKey: session.id)
            unflushedActions.removeValue(forKey: session.id)
            lastFlush.removeValue(forKey: session.id)
        }
    }

    public func allSessions() -> [TestSession] {
        Array(sessions.values)
    }

    /// Note a recorded action and flush the session's history to the store once enough have
    /// accumulated (or enough time has passed).
    ///
    /// Flushes coalesce while a write is pending; close always drains the latest snapshot.
    public func persist(_ id: String) async {
        guard store != nil, sessions[id] != nil else { return }
        let pending = (unflushedActions[id] ?? 0) + 1
        unflushedActions[id] = pending
        let elapsed = Date().timeIntervalSince(lastFlush[id] ?? .distantPast)
        guard pending >= Self.flushActionThreshold || elapsed >= Self.flushInterval else {
            if flushTimers[id] == nil {
                flushTimers[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(Self.flushInterval)) } catch { return }
                    await self?.flush(id)
                }
            }
            return
        }
        await flush(id)
    }

    /// Write a live session's current history to the store now, regardless of the batching window.
    public func flush(_ id: String) async {
        guard let store, let session = sessions[id] else { return }
        flushTimers.removeValue(forKey: id)?.cancel()
        unflushedActions[id] = 0
        lastFlush[id] = Date()
        requestedWrites[id, default: 0] += 1
        guard writers[id] == nil else { return }
        writers[id] = Task { await self.writeLatest(id, session: session, store: store) }
    }

    private func writeLatest(_ id: String, session: TestSession, store: any SessionStore) async {
        while let generation = requestedWrites[id], generation != completedWrites[id] {
            let report = await SessionReport.make(from: session)
            await store.save(report)
            completedWrites[id] = generation
        }
        writers[id] = nil
    }

    /// Wait for the latest coalesced snapshot of every session, including writes queued while draining.
    public func drainPendingWrites() async {
        while let writer = writers.values.first {
            await writer.value
        }
    }

    /// Reports pending batches separately from the last completed store write.
    public func recordingHealth(for id: String) async -> String {
        guard let store else { return "disabled" }
        let health = await store.recordingHealth(sessionID: id)
        // Recheck after suspension: a new flush may have arrived while consulting the store.
        if (unflushedActions[id] ?? 0) > 0 || requestedWrites[id] != completedWrites[id] {
            return "pending"
        }
        return health
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
            return loaded
        }
        return nil
    }

    /// Every known session as a report — live sessions merged over disk reports,
    /// live winning on id collision. Sorted by start time.
    public func allReports(includeActions: Bool = true) async -> [SessionReport] {
        var byID: [String: SessionReport] = [:]
        if let store {
            let stored = if includeActions {
                await store.loadAllReports()
            } else {
                await store.loadAllSummaries()
            }
            for report in stored {
                byID[report.sessionID] = report
            }
        }
        for (id, report) in closedReports {
            byID[id] = includeActions ? report : report.summary
        }
        for (id, session) in sessions {
            byID[id] = await session.reportSnapshot(includeActions: includeActions)
        }
        return byID.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func listAvailableDevices(
        platform: Platform?,
        includeOffline: Bool = false
    ) async throws -> [DeviceInfo] {
        try await bootstrapper.listDevices(platform: platform, includeOffline: includeOffline)
    }

    /// Boot (or resolve, if already running) the device matching `hint`.
    public func bootDevice(hint: String, platform: Platform) async throws -> DeviceInfo {
        try await bootstrapper.bootDevice(hint: hint, platform: platform)
    }

    /// Start building + installing the companion in the background; returns immediately.
    public func warmCompanion(
        platform: Platform,
        deviceHint: String?,
        appID: String?
    ) async throws -> String {
        try await bootstrapper.warmCompanion(platform: platform, deviceHint: deviceHint, appID: appID)
    }

    /// Non-blocking one-line companion readiness report.
    public func companionStatus(platform: Platform, deviceHint: String?) async throws -> String {
        try await bootstrapper.companionStatus(platform: platform, deviceHint: deviceHint)
    }

    /// Closes every active session. Used during MCP server shutdown.
    /// Stops the companion left running for a device a session has ended on.
    public func stopCompanion(platform: Platform, deviceID: String) async {
        await bootstrapper.stopCompanion(platform: platform, deviceID: deviceID)
    }

    /// Stops and forgets a device's companion, including one a dead amoo process left behind.
    public func resetCompanion(platform: Platform, deviceHint: String?) async throws -> String {
        try await bootstrapper.resetCompanion(platform: platform, deviceHint: deviceHint)
    }

    public func closeAll() async {
        shuttingDown = true
        let active = Array(sessions.values)
        for session in active {
            await session.close(terminateApp: false)
            await flush(session.id)
        }
        await drainPendingWrites()
        sessions.removeAll()
        flushTimers.values.forEach { $0.cancel() }
        flushTimers.removeAll()
    }
}

/// Control-plane codegen intent for a session: a descriptive name/description and a path to the
/// checked-in `StudioTestContext` JSON the generated test must fit. Persisted by `SessionManager`
/// so `end_session` compiles the same plan an explicit `compile_session_to_plan` would.
public struct SessionCodegenIntent: Sendable, Equatable, Codable {
    public var testName: String?
    public var testDescription: String?
    /// Absolute path to an app-owned test-context JSON file, resolved at compile time.
    public var contextPath: String?
    /// Inline test-context JSON, an alternative to `contextPath` for callers that cannot pass a path.
    public var contextJSON: String?

    public init(
        testName: String? = nil,
        testDescription: String? = nil,
        contextPath: String? = nil,
        contextJSON: String? = nil
    ) {
        self.testName = testName
        self.testDescription = testDescription
        self.contextPath = contextPath
        self.contextJSON = contextJSON
    }

    /// Fields set on `other` win; unset fields keep the current value. Lets `compile_session_to_plan`
    /// refine an intent that `start_session` seeded without clearing what it did not mention.
    public func merging(_ other: Self) -> Self {
        Self(
            testName: other.testName ?? testName,
            testDescription: other.testDescription ?? testDescription,
            contextPath: other.contextPath ?? contextPath,
            contextJSON: other.contextJSON ?? contextJSON
        )
    }

    var isEmpty: Bool {
        testName == nil && testDescription == nil && contextPath == nil && contextJSON == nil
    }
}

public extension SessionManager {
    /// Merge control-plane codegen intent into a session (see `SessionCodegenIntent`).
    func rememberCodegenIntent(_ intent: SessionCodegenIntent, for id: String) async {
        guard !intent.isEmpty else { return }
        let base = await codegenIntent(for: id) ?? SessionCodegenIntent()
        let merged = base.merging(intent)
        sessionCodegenIntent[id] = merged
        if let session = sessions[id] {
            await session.setCodegenIntent(merged)
            await flush(id)
        } else if var report = await report(for: id) {
            report.codegenIntent = merged
            closedReports[id] = report
            await store?.save(report)
        }
    }

    /// The codegen intent accumulated for a session, if any.
    func codegenIntent(for id: String) async -> SessionCodegenIntent? {
        if let intent = sessionCodegenIntent[id] {
            return intent
        }
        return await report(for: id)?.codegenIntent
    }
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case closed(String)

    public var description: String {
        switch self {
        case let .closed(id): "Session is closed: \(id)"
        case let .notFound(id): "Session not found: \(id)"
        }
    }
}
