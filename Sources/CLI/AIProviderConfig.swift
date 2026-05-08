import Foundation
import MCPServer

private let defaultOllamaBaseURL = "http://localhost:11434"
private let defaultOllamaModel = "qwen3.6:latest"

public enum ConfiguredAIProvider: Sendable, Equatable {
    case none
    case local
    case ollama(baseURL: String, model: String)

    public var summary: String {
        switch self {
        case .none:
            "disabled"
        case .local:
            "local deterministic fallback"
        case let .ollama(baseURL, model):
            "Ollama (\(model) @ \(baseURL))"
        }
    }
}

func resolveAIProviderConfiguration(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ConfiguredAIProvider {
    let provider = normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_PROVIDER"])?.lowercased()
    let hasOllamaOverrides = normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_BASE_URL"]) != nil ||
        normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_MODEL"]) != nil

    switch provider {
    case nil:
        if hasOllamaOverrides {
            return .ollama(
                baseURL: normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_BASE_URL"])
                    ?? defaultOllamaBaseURL,
                model: normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_MODEL"])
                    ?? defaultOllamaModel
            )
        }
        return .none
    case "", "none", "off", "disabled":
        return .none
    case "local":
        return .local
    case "ollama":
        return .ollama(
            baseURL: normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_BASE_URL"])
                ?? defaultOllamaBaseURL,
            model: normalizedEnvironmentValue(environment["MOBILE_TESTING_AI_OLLAMA_MODEL"])
                ?? defaultOllamaModel
        )
    default:
        return .none
    }
}

func makeAIProvider(environment: [String: String] = ProcessInfo.processInfo.environment) -> (any AIProvider)? {
    switch resolveAIProviderConfiguration(environment: environment) {
    case .none:
        return nil
    case .local:
        return LocalAIProvider()
    case let .ollama(baseURL, model):
        return OllamaProvider(baseURL: baseURL, model: model)
    }
}

private func normalizedEnvironmentValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
