import Foundation

// MARK: - Wire types

/// Starts a provider-backed agent run that drives one device through a recorded amoo session.
public struct StudioAgentStartRequest: Codable, Sendable {
    public let provider: StudioProviderProfile
    /// The conversation so far; the last message is the user's request.
    public let messages: [StudioChatMessage]
    public let activeTest: StudioAuthoredTest
    public let deviceId: String
    /// `ios` or `android`.
    public let platform: String
    public let appId: String
    public let buildPath: String?
    public let launchArguments: [String]?
    /// Model turns before the run stops; defaults to 40.
    public let maxSteps: Int?

    public init(
        provider: StudioProviderProfile,
        messages: [StudioChatMessage],
        activeTest: StudioAuthoredTest,
        deviceId: String,
        platform: String,
        appId: String,
        buildPath: String? = nil,
        launchArguments: [String]? = nil,
        maxSteps: Int? = nil
    ) {
        self.provider = provider
        self.messages = messages
        self.activeTest = activeTest
        self.deviceId = deviceId
        self.platform = platform
        self.appId = appId
        self.buildPath = buildPath
        self.launchArguments = launchArguments
        self.maxSteps = maxSteps
    }
}

public struct StudioAgentStartResult: Codable, Equatable, Sendable {
    public let runId: String

    public init(runId: String) {
        self.runId = runId
    }
}

public enum StudioAgentRunState: String, Codable, Sendable {
    case running
    case awaitingApproval
    /// The model finished without asking for another tool.
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

public enum StudioAgentEventKind: String, Codable, Sendable {
    case sessionStarted
    case assistantDelta
    case assistantMessage
    case toolCall
    case toolResult
    case approvalRequired
    case approvalResolved
    case usage
    case error
    case finished
}

/// One step of an agent run, pushed as an `agent.event` notification and replayable with
/// `agent.events`. `seq` starts at 0 and increases by one per event within a run, so a client that
/// sees a gap knows to replay. Fields beyond `kind` are present only for the kinds that use them.
public struct StudioAgentEvent: Codable, Equatable, Sendable {
    public let runId: String
    public let seq: Int
    public let kind: StudioAgentEventKind
    public var text: String?
    public var callId: String?
    public var tool: String?
    /// Tool arguments as strings, with typed text reduced to its length.
    public var arguments: [String: String]?
    public var ok: Bool?
    public var approved: Bool?
    public var structuredContent: String?
    public var screenshot: StudioScreenshot?
    public var gesturePoint: StudioPoint?
    /// For `toolResult`: the session action this call recorded, which a compiled plan names
    /// `step-<actionIndex>`, so generated code can be linked back to this step's screenshot.
    public var actionIndex: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var state: StudioAgentRunState?
    public var sessionId: String?
    public var planPath: String?
    public var flowPath: String?

    public init(runId: String, seq: Int, kind: StudioAgentEventKind) {
        self.runId = runId
        self.seq = seq
        self.kind = kind
    }
}

public struct StudioAgentEventsRequest: Codable, Sendable {
    public let runId: String
    /// Return events with `seq` greater than this; omit or pass -1 for all retained events.
    public let after: Int?

    public init(runId: String, after: Int? = nil) {
        self.runId = runId
        self.after = after
    }
}

public struct StudioAgentEventsResult: Codable, Equatable, Sendable {
    public let state: StudioAgentRunState
    public let events: [StudioAgentEvent]
    /// The `seq` the next event will have.
    public let nextSeq: Int

    public init(state: StudioAgentRunState, events: [StudioAgentEvent], nextSeq: Int) {
        self.state = state
        self.events = events
        self.nextSeq = nextSeq
    }
}

public struct StudioAgentApprovalRequest: Codable, Sendable {
    public let runId: String
    public let callId: String
    public let approved: Bool

    public init(runId: String, callId: String, approved: Bool) {
        self.runId = runId
        self.callId = callId
        self.approved = approved
    }
}

public struct StudioAgentSteerRequest: Codable, Sendable {
    public let runId: String
    public let message: String

    public init(runId: String, message: String) {
        self.runId = runId
        self.message = message
    }
}

public struct StudioAgentRunRequest: Codable, Sendable {
    public let runId: String

    public init(runId: String) {
        self.runId = runId
    }
}

// MARK: - Model abstraction

/// A tool the model may call, with a JSON Schema for its arguments.
public struct StudioAgentToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: StudioJSON

    public init(name: String, description: String, parameters: StudioJSON) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// Builds the spec for a catalog tool; exhaustive value sets become `enum`.
    public init(schema: StudioToolSchema) {
        var properties: [String: StudioJSON] = [:]
        for argument in schema.arguments {
            var property: [String: StudioJSON] = [
                "type": .string(argument.type == "integer" || argument.type == "boolean" ? argument.type : "string"),
                "description": .string(argument.description)
            ]
            if let values = argument.values, !values.isEmpty {
                property[argument.valuesAreExhaustive ? "enum" : "examples"] = .array(values.map(StudioJSON.string))
            }
            properties[argument.name] = .object(property)
        }
        self.init(
            name: schema.name,
            description: schema.description,
            parameters: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(schema.arguments.filter(\.required).map { .string($0.name) })
            ])
        )
    }
}

public struct StudioAgentToolCall: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: StudioJSON]

    public init(id: String, name: String, arguments: [String: StudioJSON]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Arguments as the strings amoo's tool executor takes.
    public var stringArguments: [String: String] {
        arguments.compactMapValues { $0 == .null ? nil : $0.argumentText }
    }
}

/// A provider-neutral conversation entry.
public enum StudioAgentMessage: Sendable, Equatable {
    case user(String)
    case assistant(text: String, toolCalls: [StudioAgentToolCall])
    case toolResult(callId: String, name: String, content: String, isError: Bool)
}

/// What the model returned for one turn.
public struct StudioAgentTurn: Sendable, Equatable {
    public let text: String
    public let toolCalls: [StudioAgentToolCall]
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(text: String, toolCalls: [StudioAgentToolCall], inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// A chat model that can call tools. Implementations stream text through `onText` as it arrives.
public protocol StudioAgentModel: Sendable {
    func respond(
        system: String,
        messages: [StudioAgentMessage],
        tools: [StudioAgentToolSpec],
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> StudioAgentTurn
}

/// The device side of an agent run: a recorded amoo session. Implemented by the CLI with the same
/// session-backed executor `amoo mcp serve` uses.
public protocol StudioAgentSessionDriving: Sendable {
    func startSession(_ request: StudioAgentStartRequest) async throws -> String
    /// Runs a tool in the session; the call is recorded like an MCP call.
    func execute(sessionId: String, tool: String, arguments: [String: String]) async -> StudioAgentToolOutcome
    /// A settled screenshot that is not recorded, so it never becomes a step in a generated test.
    func observeScreen(sessionId: String) async -> StudioScreenshot?
    /// Ends the session, writing `plan.json` and `flow.json` when the session recorded actions.
    func endSession(sessionId: String) async -> StudioAgentSessionEnd
    /// Where the session's files live, for the run's event log.
    func sessionDirectory(sessionId: String) async -> URL?
}

public struct StudioAgentToolOutcome: Sendable, Equatable {
    public let output: String
    public let isError: Bool
    public let structuredContent: String?

    public init(output: String, isError: Bool, structuredContent: String? = nil) {
        self.output = output
        self.isError = isError
        self.structuredContent = structuredContent
    }
}

public struct StudioAgentSessionEnd: Sendable, Equatable {
    public let planPath: String?
    public let flowPath: String?
    public let message: String?

    public init(planPath: String?, flowPath: String?, message: String? = nil) {
        self.planPath = planPath
        self.flowPath = flowPath
        self.message = message
    }
}
