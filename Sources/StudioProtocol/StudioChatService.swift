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
    public let platform: String
    public let steps: [Step]
    public let requirements: StudioTestRequirements?
    public let compiledPlan: StudioCompiledPlan?
    public init(
        formatVersion: Int,
        name: String,
        description: String,
        platform: String,
        steps: [Step],
        requirements: StudioTestRequirements? = nil,
        compiledPlan: StudioCompiledPlan? = nil
    ) {
        self.formatVersion = formatVersion; self.name = name; self.description = description; self
            .platform = platform; self.steps = steps; self.requirements = requirements; self.compiledPlan = compiledPlan
    }
}

public struct StudioTestRequirements: Codable, Sendable {
    public let appId: String?
    public let projectPath: String?
    public let deviceName: String?
    public init(appId: String? = nil, projectPath: String? = nil, deviceName: String? = nil) {
        self.appId = appId; self.projectPath = projectPath; self.deviceName = deviceName
    }
}

public struct StudioToolOperation: Codable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let arguments: [String: String]
    public init(id: String, tool: String, arguments: [String: String] = [:]) {
        self.id = id; self.tool = tool; self.arguments = arguments
    }
}

public struct StudioCompiledPlan: Codable, Equatable, Sendable {
    public let compiler: String
    public let compilerVersion: String
    public let operations: [String]?
    public let toolOperations: [StudioToolOperation]?
    public init(
        compiler: String,
        compilerVersion: String,
        operations: [String] = [],
        toolOperations: [StudioToolOperation]? = nil
    ) {
        self.compiler = compiler; self.compilerVersion = compilerVersion; self.operations = operations; self
            .toolOperations = toolOperations
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
            throw StudioChatError.requestFailed(http.statusCode, String(decoding: data.prefix(1024), as: UTF8.self))
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
            throw StudioChatError.requestFailed(http.statusCode, String(decoding: data.prefix(1024), as: UTF8.self))
        }
        return .init(message: "Connected to \(provider.name) at \(endpoint.host ?? provider.baseUrl).")
    }

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
        <amoo-plan>{"compiler":"ai","compilerVersion":"1","toolOperations":[{"id":"operation-1","tool":"tap_element","arguments":{"id":"sign-in"}}]}</amoo-plan>
        Allowed tools: tap_element, set_text, type_text, swipe_in_direction, wait_for_element,
        assert_visible, assert_not_visible, assert_text, take_screenshot, press_back.
        Prefer accessibility IDs, never invent secrets, and keep credentials as ${ENVIRONMENT_VARIABLE} values.
        """
    }

    private static let allowedPlanTools: Set<String> = [
        "tap_element", "set_text", "type_text", "swipe_in_direction", "wait_for_element",
        "assert_visible", "assert_not_visible", "assert_text", "take_screenshot", "press_back"
    ]

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
