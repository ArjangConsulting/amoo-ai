import Foundation
import MobileTestingCore

public struct AIStatusCheck: Sendable, Equatable {
    public var id: String
    public var status: PreflightStatus
    public var message: String
    public var remediation: String

    public init(id: String, status: PreflightStatus, message: String, remediation: String) {
        self.id = id
        self.status = status
        self.message = message
        self.remediation = remediation
    }
}

public struct AIStatusReport: Sendable, Equatable {
    public var provider: ResolvedAIConfiguration
    public var checks: [AIStatusCheck]

    public init(provider: ResolvedAIConfiguration, checks: [AIStatusCheck]) {
        self.provider = provider
        self.checks = checks
    }

    public var hasFailures: Bool {
        checks.contains(where: { $0.status == .fail })
    }
}

public protocol AIStatusChecking: Sendable {
    func run(environment: [String: String]) async -> AIStatusReport
}

public struct DefaultAIStatusChecker: AIStatusChecking {
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let resolver: AIConfigurationResolver

    public init(resolver: AIConfigurationResolver = AIConfigurationResolver()) {
        self.resolver = resolver
        transport = { request in
            try await URLSession.shared.data(for: request)
        }
    }

    init(
        resolver: AIConfigurationResolver = AIConfigurationResolver(),
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.resolver = resolver
        self.transport = transport
    }

    public func run(environment: [String: String]) async -> AIStatusReport {
        let provider = (try? resolver.resolve(environment: environment)) ?? ResolvedAIConfiguration(provider: .disabled, source: "default")

        switch provider.provider {
        case .disabled:
            return AIStatusReport(provider: provider, checks: [
                AIStatusCheck(
                    id: "ai.provider",
                    status: .pass,
                    message: "AI provider is disabled. ai_* tools will use deterministic fallback behavior.",
                    remediation: "Set MOBILE_TESTING_AI_PROVIDER=ollama or local to enable an AI provider."
                )
            ])

        case .local:
            return AIStatusReport(provider: provider, checks: [
                AIStatusCheck(
                    id: "ai.provider",
                    status: .pass,
                    message: "Using the local deterministic provider from \(provider.source).",
                    remediation: "Set MOBILE_TESTING_AI_PROVIDER=ollama to use a real model."
                )
            ])

        case .ollama:
            return await checkOllama(
                baseURL: provider.baseURL ?? defaultOllamaBaseURL,
                model: provider.model ?? defaultOllamaModel,
                provider: provider
            )
        }
    }

    private func checkOllama(baseURL: String, model: String, provider: ResolvedAIConfiguration) async -> AIStatusReport {
        var checks: [AIStatusCheck] = [
            AIStatusCheck(
                id: "ai.provider",
                status: .pass,
                message: "Using Ollama at \(baseURL) with model \(model) from \(provider.source).",
                remediation: "Adjust MOBILE_TESTING_AI_OLLAMA_BASE_URL or MOBILE_TESTING_AI_OLLAMA_MODEL if needed."
            )
        ]

        do {
            let models = try await fetchOllamaModels(baseURL: baseURL)
            checks.append(AIStatusCheck(
                id: "ai.ollama.reachable",
                status: .pass,
                message: "Ollama server is reachable.",
                remediation: "Keep Ollama running while using ai_* tools."
            ))

            if models.contains(model) {
                checks.append(AIStatusCheck(
                    id: "ai.ollama.model",
                    status: .pass,
                    message: "Model \(model) is installed.",
                    remediation: "None."
                ))
            } else {
                checks.append(AIStatusCheck(
                    id: "ai.ollama.model",
                    status: .fail,
                    message: "Model \(model) is not available in Ollama.",
                    remediation: "Run `ollama pull \(model)` or change MOBILE_TESTING_AI_OLLAMA_MODEL."
                ))
            }
        } catch {
            checks.append(AIStatusCheck(
                id: "ai.ollama.reachable",
                status: .fail,
                message: "Failed to reach Ollama: \(error)",
                remediation: "Start Ollama and verify MOBILE_TESTING_AI_OLLAMA_BASE_URL points to a running server."
            ))
        }

        return AIStatusReport(provider: provider, checks: checks)
    }

    private func fetchOllamaModels(baseURL: String) async throws -> Set<String> {
        try await loadOllamaModels(baseURL: baseURL, transport: transport)
    }
}

enum AICommandParseError: Error, CustomStringConvertible {
    case missingAction
    case unknownAction(String)

    var description: String {
        switch self {
        case .missingAction:
            "Usage: mobile-testing ai <setup|status|config|reset>"
        case let .unknownAction(action):
            "Unknown ai action '\(action)'. Run 'mobile-testing ai' for usage."
        }
    }
}

enum AICommandAction: String, Equatable {
    case setup
    case status
    case config
    case reset
}

func parseAICommand(args: [String]) -> Result<AICommandAction, AICommandParseError> {
    guard let action = args.first else {
        return .failure(.missingAction)
    }

    switch action {
    case "setup":
        return .success(.setup)
    case "status":
        return .success(.status)
    case "config":
        return .success(.config)
    case "reset":
        return .success(.reset)
    default:
        return .failure(.unknownAction(action))
    }
}

func runAIStatusCommand(
    checker: any AIStatusChecking,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> CLIResult {
    let report = await checker.run(environment: environment)
    return CLIResult(output: renderAIStatusReport(report), exitCode: report.hasFailures ? 1 : 0)
}

func renderAIConfig(_ configuration: ResolvedAIConfiguration) -> String {
    var lines = [
        "provider: \(configuration.provider.rawValue)",
        "source: \(configuration.source)"
    ]

    if let baseURL = configuration.baseURL {
        lines.append("base_url: \(baseURL)")
    }
    if let model = configuration.model {
        lines.append("model: \(model)")
    }

    return lines.joined(separator: "\n")
}

func renderAIStatusReport(_ report: AIStatusReport) -> String {
    let statusText = report.hasFailures
        ? colored("FAIL", .bold, .red)
        : colored("PASS", .bold, .green)

    var lines = ["ai status \(statusText)", "provider: \(report.provider.summary)"]

    for check in report.checks {
        let badge = check.status == .pass ? colored("[PASS]", .green) : colored("[FAIL]", .red)
        lines.append("\(badge) \(check.id) - \(check.message)")
        if check.status == .fail {
            lines.append("  \(colored("remediation:", .yellow)) \(check.remediation)")
        }
    }

    return lines.joined(separator: "\n")
}

func loadOllamaModels(
    baseURL: String,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
) async throws -> Set<String> {
    guard let url = makeOllamaTagsURL(baseURL: baseURL) else {
        throw OllamaStatusError.invalidBaseURL(baseURL)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    let (data, response) = try await transport(request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw OllamaStatusError.invalidResponse
    }
    guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw OllamaStatusError.httpError(statusCode: httpResponse.statusCode, body: body)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let models = json["models"] as? [[String: Any]]
    else {
        throw OllamaStatusError.invalidJSON
    }

    return Set(models.compactMap { $0["name"] as? String })
}

private func makeOllamaTagsURL(baseURL: String) -> URL? {
    guard var components = URLComponents(string: baseURL) else { return nil }
    components.path = normalizedOllamaBasePath(components.path) + "/api/tags"
    return components.url
}

private func normalizedOllamaBasePath(_ path: String) -> String {
    guard !path.isEmpty, path != "/" else { return "" }
    return path.hasSuffix("/") ? String(path.dropLast()) : path
}

enum OllamaStatusError: Error, Sendable {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case invalidJSON
}
