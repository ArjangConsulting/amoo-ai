import AmooLogging
import Foundation

public enum StudioAgentError: Error, CustomStringConvertible {
    case runNotFound(String)
    case invalidRequest(String)
    case approvalNotPending(String)

    public var description: String {
        switch self {
        case let .runNotFound(id): "Agent run not found: \(id)"
        case let .invalidRequest(reason): "Invalid agent request: \(reason)"
        case let .approvalNotPending(id): "No approval is waiting for call \(id)."
        }
    }
}

/// Starts and tracks agent runs for `amoo studio serve`. One run at a time drives a device; finished
/// runs stay available for `agent.events` replay until the service has kept `retainedRuns` of them.
public actor StudioAgentService {
    private let session: any StudioSessionDriving
    private let deviceSessions: StudioDeviceSessions
    private let catalog: any StudioToolCatalogProviding
    private let notifications: StudioNotificationCenter?
    private let deviceLocks: StudioDeviceLocks
    private let modelFactory: @Sendable (StudioProviderProfile) -> any StudioAgentModel
    private let logger = AmooLogger.forType(StudioAgentService.self)
    private var runs: [String: StudioAgentRun] = [:]
    private var order: [String] = []
    private static let retainedRuns = 20

    public init(
        session: any StudioSessionDriving,
        catalog: any StudioToolCatalogProviding,
        notifications: StudioNotificationCenter? = nil,
        deviceLocks: StudioDeviceLocks = .init(),
        deviceSessions: StudioDeviceSessions = .init(),
        modelFactory: @escaping @Sendable (StudioProviderProfile)
            -> any StudioAgentModel = { StudioAgentModels.model(for: $0) }
    ) {
        self.session = session
        self.catalog = catalog
        self.notifications = notifications
        self.deviceLocks = deviceLocks
        self.deviceSessions = deviceSessions
        self.modelFactory = modelFactory
    }

    public func start(_ request: StudioAgentStartRequest) async throws -> StudioAgentStartResult {
        guard request.messages.last?.role == .user,
              request.messages.last?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { throw StudioAgentError.invalidRequest("The last message must be the user's request.") }
        guard !request.appId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StudioAgentError.invalidRequest("An app ID is required so the session can launch the app.")
        }
        guard ["ios", "android"].contains(request.platform.lowercased()) else {
            throw StudioAgentError.invalidRequest("Platform must be ios or android.")
        }
        // The agent gets the console's tools: lifecycle tools are Studio's job. `run_steps` is left
        // out because it records one action per inner step, which would break the link between
        // timeline events and compiled plan steps.
        let tools = catalog.tools().filter { $0.replSupported && $0.name != "run_steps" }
        let run = StudioAgentRun(
            id: UUID().uuidString,
            request: request,
            model: modelFactory(request.provider),
            session: session,
            tools: tools,
            notifications: notifications,
            deviceLocks: deviceLocks,
            deviceSessions: deviceSessions
        )
        // One recorded session per device: a console recording or another run must finish first.
        try await deviceSessions.claim(request.deviceId, for: run.owner)
        runs[run.id] = run
        order.append(run.id)
        await pruneFinishedRuns()
        await run.start()
        logger.info("Agent run accepted", context: "runId=\(run.id) deviceId=\(request.deviceId) tools=\(tools.count)")
        return .init(runId: run.id)
    }

    public func events(_ request: StudioAgentEventsRequest) async throws -> StudioAgentEventsResult {
        try await run(request.runId).events(after: request.after)
    }

    public func approve(_ request: StudioAgentApprovalRequest) async throws -> StudioAgentEventsResult {
        let run = try run(request.runId)
        guard await run.approve(callId: request.callId, approved: request.approved) else {
            throw StudioAgentError.approvalNotPending(request.callId)
        }
        return await run.events(after: nil)
    }

    public func steer(_ request: StudioAgentSteerRequest) async throws -> StudioAgentEventsResult {
        let run = try run(request.runId)
        guard await run.steer(request.message) else {
            throw StudioAgentError.invalidRequest("The run has already finished; start a new one.")
        }
        return await run.events(after: nil)
    }

    public func cancel(_ request: StudioAgentRunRequest) async throws -> StudioAgentEventsResult {
        let run = try run(request.runId)
        await run.cancel()
        return await run.events(after: nil)
    }

    /// Cancels every run and waits for their sessions to end, for orderly shutdown and tests.
    public func cancelAll() async {
        for run in runs.values {
            await run.cancel()
            await run.waitUntilFinished()
        }
    }

    func waitForRun(_ id: String) async {
        await runs[id]?.waitUntilFinished()
    }

    private func run(_ id: String) throws -> StudioAgentRun {
        guard let run = runs[id] else { throw StudioAgentError.runNotFound(id) }
        return run
    }

    private func pruneFinishedRuns() async {
        guard order.count > Self.retainedRuns else { return }
        var kept: [String] = []
        for id in order {
            guard let run = runs[id] else { continue }
            if order.count - kept.count > Self.retainedRuns, await run.state.isTerminal {
                runs[id] = nil
            } else {
                kept.append(id)
            }
        }
        order = kept
    }
}
