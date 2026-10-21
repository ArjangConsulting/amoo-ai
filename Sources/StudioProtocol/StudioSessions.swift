import Foundation

/// What a recorded session targets: the device, and the app the session launches fresh.
public struct StudioSessionSpec: Codable, Equatable, Sendable {
    public let deviceId: String
    /// `ios` or `android`.
    public let platform: String
    public let appId: String
    public let buildPath: String?
    public let launchArguments: [String]?
    public let testName: String?
    public let testDescription: String?

    public init(
        deviceId: String,
        platform: String,
        appId: String,
        buildPath: String? = nil,
        launchArguments: [String]? = nil,
        testName: String? = nil,
        testDescription: String? = nil
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.appId = appId
        self.buildPath = buildPath
        self.launchArguments = launchArguments
        self.testName = testName
        self.testDescription = testDescription
    }
}

/// Recorded amoo sessions for Studio: agent runs and console recordings. Implemented by the CLI with
/// the same session-backed executor `amoo mcp serve` uses, so `endSession` writes `plan.json` and
/// `flow.json` that test generation reads.
public protocol StudioSessionDriving: Sendable {
    func startSession(_ spec: StudioSessionSpec) async throws -> String
    /// Runs a tool in the session; the call is recorded like an MCP call.
    func execute(sessionId: String, tool: String, arguments: [String: String]) async -> StudioAgentToolOutcome
    /// A settled screenshot that is not recorded, so it never becomes a step in a generated test.
    func observeScreen(sessionId: String) async -> StudioScreenshot?
    /// Elements on screen for completion, queried without recording.
    func observeElements(sessionId: String) async -> [StudioElementSuggestion]
    /// Ends the session, writing `plan.json` and `flow.json` when the session recorded actions.
    func endSession(sessionId: String) async -> StudioAgentSessionEnd
    /// Where the session's files live.
    func sessionDirectory(sessionId: String) async -> URL?
}

public enum StudioSessionError: Error, CustomStringConvertible {
    case deviceBusy(deviceId: String, owner: String)

    public var description: String {
        switch self {
        case let .deviceBusy(deviceId, owner):
            "Device \(deviceId) is already recording a session for \(owner). Stop it before starting another."
        }
    }
}

/// Which Studio workflow owns each device's recorded session. A device records one session at a time,
/// so an agent run and a console recording never fight over it.
public actor StudioDeviceSessions {
    private var owners: [String: String] = [:]

    public init() {}

    /// Claims `deviceId` for `owner`, such as "an agent run" or "the console".
    public func claim(_ deviceId: String, for owner: String) throws {
        if let current = owners[deviceId], current != owner {
            throw StudioSessionError.deviceBusy(deviceId: deviceId, owner: current)
        }
        owners[deviceId] = owner
    }

    public func release(_ deviceId: String, from owner: String) {
        if owners[deviceId] == owner {
            owners[deviceId] = nil
        }
    }

    public func owner(of deviceId: String) -> String? {
        owners[deviceId]
    }
}
