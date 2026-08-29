import AmooCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StudioProviderKind: String, Codable, Sendable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case ollama = "Ollama"
    case custom = "Custom"
}

public struct StudioProviderProfile: Codable, Sendable {
    public let id: String
    public let name: String
    public let kind: StudioProviderKind
    public let baseUrl: String
    public let model: String
    public let apiKeyEnvironmentVariable: String
    public init(
        id: String,
        name: String,
        kind: StudioProviderKind,
        baseUrl: String,
        model: String,
        apiKeyEnvironmentVariable: String
    ) {
        self.id = id; self.name = name; self.kind = kind; self.baseUrl = baseUrl; self.model = model; self
            .apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
    }
}

public struct StudioChatMessage: Codable, Sendable {
    public enum Role: String, Codable, Sendable { case user = "User"; case assistant = "Assistant" }
    public let id: String
    public let role: Role
    public let content: String
    public init(id: String, role: Role, content: String) {
        self.id = id; self.role = role; self.content = content
    }
}

public struct StudioAuthoredTest: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public let id: String; public let instruction: String; public let expected: String
        public init(id: String, instruction: String, expected: String) {
            self.id = id; self.instruction = instruction; self.expected = expected
        }
    }

    public let formatVersion: Int
    public let name: String
    public let description: String
    public let platform: Platform
    public let steps: [Step]
    public let requirements: StudioTestRequirements?
    /// App-owned test harness and helper metadata approved for generated tests to use.
    public let testContext: StudioTestContext?
    public let compiledPlan: StudioCompiledPlan?
    public init(
        formatVersion: Int,
        name: String,
        description: String,
        platform: Platform,
        steps: [Step],
        requirements: StudioTestRequirements? = nil,
        testContext: StudioTestContext? = nil,
        compiledPlan: StudioCompiledPlan? = nil
    ) {
        self.formatVersion = formatVersion; self.name = name; self.description = description; self
            .platform = platform; self.steps = steps; self.requirements = requirements; self.testContext = testContext
        self.compiledPlan = compiledPlan
    }

    /// Convenience for callers constructing tests from CLI or fixture strings.
    ///
    /// Returns `nil` rather than guessing on an unrecognized platform: defaulting to one platform
    /// would turn a typo into a test generated for the wrong OS, which is the same silent-degradation
    /// failure the decoder deliberately throws on.
    public init?(
        formatVersion: Int,
        name: String,
        description: String,
        platform: String,
        steps: [Step],
        requirements: StudioTestRequirements? = nil,
        testContext: StudioTestContext? = nil,
        compiledPlan: StudioCompiledPlan? = nil
    ) {
        guard let resolved = Platform(lenient: platform) else { return nil }
        self.init(
            formatVersion: formatVersion,
            name: name,
            description: description,
            platform: resolved,
            steps: steps,
            requirements: requirements,
            testContext: testContext,
            compiledPlan: compiledPlan
        )
    }

    public func replacingTestContext(_ testContext: StudioTestContext) -> Self {
        Self(
            formatVersion: formatVersion,
            name: name,
            description: description,
            platform: platform,
            steps: steps,
            requirements: requirements,
            testContext: testContext,
            compiledPlan: compiledPlan
        )
    }
}

/// Checked-in, app-owned metadata that makes exported tests fit the host test target.
/// A helper is used only when a compiled operation explicitly names it; generation never guesses.
public struct StudioTestContext: Codable, Equatable, Sendable {
    public struct Helper: Codable, Equatable, Sendable {
        public let name: String
        /// A Swift/Kotlin call expression. `{{argument_name}}` placeholders are string-literal escaped.
        public let callTemplate: String
        public let imports: [String]

        public init(name: String, callTemplate: String, imports: [String] = []) {
            self.name = name; self.callTemplate = callTemplate; self.imports = imports
        }
    }

    public let imports: [String]
    public let baseClass: String?
    /// An expression that constructs the app under test, e.g. `makeApp()`. Constructs only — the
    /// emitter adds `app.launch()` itself unless `harnessLaunchesApp` says otherwise.
    public let appFactory: String?
    /// `true` when the base class or app factory already launches the app, so the generated
    /// `setUpWithError` must not launch it a second time.
    ///
    /// This is declared, never inferred. A supplied `baseClass` is not evidence either way: an
    /// app may name `XCTestCase` explicitly and still expect the emitter to launch, and a custom
    /// base class may do nothing but register fixtures. Guessing here either double-launches or
    /// silently runs every generated test against an app that was never launched.
    public let harnessLaunchesApp: Bool
    public let helpers: [Helper]

    public init(
        imports: [String] = [],
        baseClass: String? = nil,
        appFactory: String? = nil,
        harnessLaunchesApp: Bool = false,
        helpers: [Helper] = []
    ) {
        self.imports = imports; self.baseClass = baseClass; self.appFactory = appFactory
        self.harnessLaunchesApp = harnessLaunchesApp; self.helpers = helpers
    }

    private enum CodingKeys: String, CodingKey {
        case imports, baseClass, appFactory, harnessLaunchesApp, helpers
    }

    /// `harnessLaunchesApp` was added after context files were already checked in. Absence decodes
    /// as `false` — the emitter keeps launching — so an existing file behaves exactly as before.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imports = try container.decodeIfPresent([String].self, forKey: .imports) ?? []
        baseClass = try container.decodeIfPresent(String.self, forKey: .baseClass)
        appFactory = try container.decodeIfPresent(String.self, forKey: .appFactory)
        harnessLaunchesApp = try container.decodeIfPresent(Bool.self, forKey: .harnessLaunchesApp) ?? false
        helpers = try container.decodeIfPresent([Helper].self, forKey: .helpers) ?? []
    }

    public func helper(named name: String) -> Helper? {
        helpers.first { $0.name == name }
    }
}

public struct StudioTestRequirements: Codable, Sendable {
    public let appId: String?
    public let projectPath: String?
    public let deviceName: String?
    public let uiToolkit: UIToolkit?
    public init(
        appId: String? = nil,
        projectPath: String? = nil,
        deviceName: String? = nil,
        uiToolkit: UIToolkit? = nil
    ) {
        self.appId = appId; self.projectPath = projectPath; self.deviceName = deviceName; self.uiToolkit = uiToolkit
    }
}

public struct StudioToolOperation: Codable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let arguments: [String: String]
    /// The context helper deliberately selected by the planner for this operation.
    public let helper: String?
    public init(id: String, tool: String, arguments: [String: String] = [:], helper: String? = nil) {
        self.id = id; self.tool = tool; self.arguments = arguments; self.helper = helper
    }

    /// A copy that routes through `helper` instead of the tool's default emission. Used by the
    /// `generate test` context pass to bind an operation to a declared helper whose call template
    /// matches its selector shape — never overrides a helper the planner already chose.
    public func bindingHelper(_ helper: String) -> Self {
        Self(id: id, tool: tool, arguments: arguments, helper: self.helper ?? helper)
    }
}

/// One recorded action that did not survive compilation into `StudioCompiledPlan.toolOperations`
/// unchanged — either dropped entirely, or included with a loosened meaning.
///
/// These are stored *inside* the compiled plan rather than only returned alongside it, so a plan
/// written to disk stays self-describing: `amoo generate test` reading a `.amootest` file hours
/// later can still tell that steps went missing, instead of silently emitting a shorter test.
public struct StudioPlanWarning: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Dropped from `toolOperations`: the recorded tool has no Studio equivalent yet. This is a
        /// gap in the vocabulary, and generating from such a plan produces an incomplete test.
        case excluded
        /// Deliberately omitted: a query/inspection tool with no effect on the app, which has no
        /// place in generated test code. Expected, not a gap.
        case notApplicable
        /// Included, but a selector or assertion was mapped loosely and should be reviewed.
        case approximate
        /// Included, but carries a redacted value that must be hand-filled before the test runs.
        case redacted
    }

    public let kind: Kind
    public let actionIndex: Int
    public let toolName: String
    public let reason: String
    /// True when the action targeted system UI (a permission alert, the "Sign in with Apple" sheet)
    /// or a known dismissable overlay (paywall, coach-mark, tooltip). Test-mode / mock builds usually
    /// suppress these, so a finalize pass can drop the step once it knows the build does — but only
    /// if the compiler tells it which steps qualify.
    public let transient: Bool

    public init(kind: Kind, actionIndex: Int, toolName: String, reason: String, transient: Bool = false) {
        self.kind = kind
        self.actionIndex = actionIndex
        self.toolName = toolName
        self.reason = reason
        self.transient = transient
    }

    private enum CodingKeys: String, CodingKey {
        case kind, actionIndex, toolName, reason, transient
    }

    /// `transient` was added after plans were already being written to disk. Absence decodes as
    /// `false` so an older plan still round-trips instead of failing to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        actionIndex = try container.decode(Int.self, forKey: .actionIndex)
        toolName = try container.decode(String.self, forKey: .toolName)
        reason = try container.decode(String.self, forKey: .reason)
        transient = try container.decodeIfPresent(Bool.self, forKey: .transient) ?? false
    }
}

public struct StudioCompiledPlan: Codable, Equatable, Sendable {
    public let compiler: String
    public let compilerVersion: String
    public let operations: [String]?
    public let toolOperations: [StudioToolOperation]?
    /// Actions that did not compile cleanly. `nil` on plans written before this field existed —
    /// absence means "unknown", not "none".
    public let warnings: [StudioPlanWarning]?

    /// Actions dropped because the vocabulary has no equivalent — the subset of `warnings` that
    /// makes generated code incomplete rather than merely imprecise.
    public var excludedWarnings: [StudioPlanWarning] {
        (warnings ?? []).filter { $0.kind == .excluded }
    }

    public init(
        compiler: String,
        compilerVersion: String,
        operations: [String] = [],
        toolOperations: [StudioToolOperation]? = nil,
        warnings: [StudioPlanWarning]? = nil
    ) {
        self.compiler = compiler; self.compilerVersion = compilerVersion; self.operations = operations; self
            .toolOperations = toolOperations; self.warnings = warnings
    }
}

public struct StudioChatRequest: Codable, Sendable {
    public let provider: StudioProviderProfile
    public let messages: [StudioChatMessage]
    public let activeTest: StudioAuthoredTest
    public init(provider: StudioProviderProfile, messages: [StudioChatMessage], activeTest: StudioAuthoredTest) {
        self.provider = provider; self.messages = messages; self.activeTest = activeTest
    }
}

public struct StudioChatResult: Codable, Equatable, Sendable {
    public let message: String
    public let proposedPlan: StudioCompiledPlan?
    public init(message: String, proposedPlan: StudioCompiledPlan? = nil) {
        self.message = message; self.proposedPlan = proposedPlan
    }
}

public protocol StudioChatServing: Sendable {
    func send(_ request: StudioChatRequest) async throws -> StudioChatResult
    func check(_ provider: StudioProviderProfile) async throws -> StudioProviderCheckResult
}

public struct StudioProviderCheckResult: Codable, Equatable, Sendable {
    public let message: String
    public init(message: String) {
        self.message = message
    }
}

public protocol StudioHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// swift-corelibs-foundation's `URLSession.data(for:)` takes an extra `delegate` parameter on
/// Linux, so it can't satisfy `StudioHTTPTransport` via a direct `extension URLSession` the way
/// it can on Darwin. Route through a thin wrapper instead so both platforms compile identically.
private struct URLSessionTransport: StudioHTTPTransport {
    let session: URLSession

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public enum StudioChatError: Error, CustomStringConvertible {
    case invalidEndpoint, missingSecret(String), invalidResponse, requestFailed(Int, String)

    public var description: String {
        switch self {
        case .invalidEndpoint: "The provider endpoint is invalid."
        case let .missingSecret(name): "The environment variable \(name) is not set."
        case .invalidResponse: "The provider returned an invalid chat response."
        case let .requestFailed(code, message): "Provider request failed (HTTP \(code)): \(message)"
        }
    }
}

public struct LiveStudioChatService: StudioChatServing {
    private let transport: any StudioHTTPTransport
    private let environment: @Sendable (String) -> String?

    public init() {
        transport = URLSessionTransport(session: URLSession(configuration: .default))
        environment = { ProcessInfo.processInfo.environment[$0] }
    }

    public init(transport: any StudioHTTPTransport, environment: @escaping @Sendable (String) -> String?) {
        self.transport = transport
        self.environment = environment
    }

    public func send(_ input: StudioChatRequest) async throws -> StudioChatResult {
        let provider = input.provider
        guard var endpoint = URL(string: provider.baseUrl) else { throw StudioChatError.invalidEndpoint }
        endpoint
            .append(path: provider.kind == .ollama ? "api/chat" : provider
                .kind == .anthropic ? "v1/messages" : "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if provider.kind != .ollama {
            let variable = provider.apiKeyEnvironmentVariable
            guard variable.isEmpty == false, let secret = environment(variable), secret.isEmpty == false else {
                throw StudioChatError.missingSecret(variable.isEmpty ? "provider API key" : variable)
            }
            if provider.kind == .anthropic {
                request.setValue(secret, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        }

        let messages = input.messages.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.content] }
        let testContext = Self.testContext(input.activeTest)
        var body: [String: Any] = ["model": provider.model, "stream": false]
        if provider.kind == .anthropic {
            body["messages"] = messages
            body["system"] = testContext
            body["max_tokens"] = 4096
        } else {
            body["messages"] = [["role": "system", "content": testContext]] + messages
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StudioChatError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw StudioChatError.requestFailed(
                http.statusCode,
                String(bytes: data.prefix(1024), encoding: .utf8) ?? "<non-UTF8 response>"
            )
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content: String? = if provider.kind == .ollama {
            (object?["message"] as? [String: Any])?["content"] as? String
        } else if provider.kind == .anthropic {
            (object?["content"] as? [[String: Any]])?.first?["text"] as? String
        } else {
            ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let content, content.isEmpty == false else { throw StudioChatError.invalidResponse }
        let proposal = Self.extractPlan(from: content)
        return StudioChatResult(message: proposal?.message ?? content, proposedPlan: proposal?.plan)
    }

    public func check(_ provider: StudioProviderProfile) async throws -> StudioProviderCheckResult {
        guard var endpoint = URL(string: provider.baseUrl) else { throw StudioChatError.invalidEndpoint }
        endpoint.append(path: provider.kind == .ollama ? "api/tags" : "v1/models")
        var request = URLRequest(url: endpoint)
        if provider.kind != .ollama {
            let variable = provider.apiKeyEnvironmentVariable
            guard !variable.isEmpty, let secret = environment(variable), !secret.isEmpty else {
                throw StudioChatError.missingSecret(variable.isEmpty ? "provider API key" : variable)
            }
            if provider.kind == .anthropic {
                request.setValue(secret, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
            }
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StudioChatError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw StudioChatError.requestFailed(
                http.statusCode,
                String(bytes: data.prefix(1024), encoding: .utf8) ?? "<non-UTF8 response>"
            )
        }
        return .init(message: "Connected to \(provider.name) at \(endpoint.host ?? provider.baseUrl).")
    }

    /// The `<amoo-plan>` tag the model is told to copy. Assembled from parts so no source line runs
    /// long — the emitted string is still a single line, which is what `extractPlan` looks for.
    private static let planTagExample: String = {
        let operation = #"{"id":"operation-1","tool":"tap_element","arguments":{"id":"sign-in"}}"#
        let plan = #"{"compiler":"ai","compilerVersion":"1","toolOperations":["# + operation + "]}"
        return "<amoo-plan>" + plan + "</amoo-plan>"
    }()

    private static func testContext(_ test: StudioAuthoredTest) -> String {
        let steps = test.steps.enumerated().map { index, step in
            "\(index + 1). \(step.instruction)\(step.expected.isEmpty ? "" : " Expected: \(step.expected)")"
        }.joined(separator: "\n")
        return """
        You are assisting with the active Amoo test '\(test.name)' on \(test.platform).
        Description: \(test.description)
        Steps:
        \(steps)

        When the user asks to create or revise an executable test, include one machine-readable plan
        after your explanation using exactly these tags:
        \(planTagExample)
        Allowed tools: \(StudioTool.allNames.joined(separator: ", ")).
        Note scroll takes the direction the content moves (scroll down reveals content below),
        which is the opposite of swipe_in_direction's raw finger direction.
        Prefer a stable accessibility identifier over a raw label or visible text for every selector
        and every assertion — text changes with copy and locale, identifiers do not.
        When a step inspects the screen right before a state change, encode it as an assertion
        (assert_visible / assert_text) rather than leaving it implicit.
        Never propose a coordinate tap for a checked-in test. If an element cannot be reached by
        identifier, say "this element needs an accessibility identifier" instead of tapping a point.
        Never invent secrets, and keep credentials as ${ENVIRONMENT_VARIABLE} values.
        """
    }

    private static let allowedPlanTools = Set(StudioTool.allNames)

    private static func extractPlan(from content: String) -> (message: String, plan: StudioCompiledPlan)? {
        guard let start = content.range(of: "<amoo-plan>"),
              let end = content.range(of: "</amoo-plan>", range: start.upperBound ..< content.endIndex)
        else { return nil }
        let data = Data(content[start.upperBound ..< end.lowerBound].utf8)
        guard let plan = try? JSONDecoder().decode(StudioCompiledPlan.self, from: data),
              let operations = plan.toolOperations,
              !operations.isEmpty,
              operations.allSatisfy({ allowedPlanTools.contains($0.tool) })
        else { return nil }
        var message = content
        message.removeSubrange(start.lowerBound ..< end.upperBound)
        return (message.trimmingCharacters(in: .whitespacesAndNewlines), plan)
    }
}
