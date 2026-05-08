import Foundation

public protocol AISetupPrompting: Sendable {
    func chooseProvider(defaultProvider: AIProviderKind) async -> AIProviderKind?
    func askString(prompt: String, defaultValue: String?) async -> String?
    func askBool(prompt: String, defaultValue: Bool) async -> Bool?
}

public struct ConsoleAISetupPrompter: AISetupPrompting {
    public init() {}

    public func chooseProvider(defaultProvider: AIProviderKind) async -> AIProviderKind? {
        print("Choose AI provider:")
        print("  1. Ollama")
        print("  2. Local deterministic fallback")
        print("  3. Disable AI")

        let defaultText: String = switch defaultProvider {
        case .ollama: "1"
        case .local: "2"
        case .disabled: "3"
        }

        guard let value = readLineWithPrompt("Provider [\(defaultText)]: ") else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = trimmed.isEmpty ? defaultText : trimmed

        switch choice {
        case "1", "ollama", "Ollama": return .ollama
        case "2", "local": return .local
        case "3", "disabled", "none": return .disabled
        default: return nil
        }
    }

    public func askString(prompt: String, defaultValue: String?) async -> String? {
        let rendered = if let defaultValue {
            "\(prompt) [\(defaultValue)]: "
        } else {
            "\(prompt): "
        }

        guard let value = readLineWithPrompt(rendered) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return defaultValue
        }
        return trimmed
    }

    public func askBool(prompt: String, defaultValue: Bool) async -> Bool? {
        let rendered = "\(prompt) [\(defaultValue ? "Y/n" : "y/N")]: "
        guard let value = readLineWithPrompt(rendered) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return defaultValue }
        switch trimmed {
        case "y", "yes": return true
        case "n", "no": return false
        default: return nil
        }
    }

    private func readLineWithPrompt(_ prompt: String) -> String? {
        Swift.print(prompt, terminator: "")
        fflush(stdout)
        return readLine()
    }
}

public struct AISetupResult: Sendable, Equatable {
    var configuration: AIProviderConfiguration
    var shouldPersist: Bool
}

public enum AISetupError: Error, CustomStringConvertible {
    case cancelled
    case invalidSelection

    public var description: String {
        switch self {
        case .cancelled:
            "AI setup cancelled."
        case .invalidSelection:
            "Invalid setup selection. Please try again."
        }
    }
}

public struct AISetupWizard: Sendable {
    let prompt: any AISetupPrompting
    let registry: AIProviderRegistry
    let settingsStore: any AISettingsStore

    public init(
        prompt: any AISetupPrompting = ConsoleAISetupPrompter(),
        registry: AIProviderRegistry = AIProviderRegistry(),
        settingsStore: any AISettingsStore = FileAISettingsStore()
    ) {
        self.prompt = prompt
        self.registry = registry
        self.settingsStore = settingsStore
    }

    public func runPersistentSetup(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> AISetupResult {
        let result = try await collectConfiguration(environment: environment, persistPrompt: true)
        if result.shouldPersist {
            try settingsStore.save(result.configuration)
        }
        return result
    }

    public func runOneTimeSetup(environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> AIProviderConfiguration {
        let result = try await collectConfiguration(environment: environment, persistPrompt: false)
        return result.configuration
    }

    private func collectConfiguration(
        environment: [String: String],
        persistPrompt: Bool
    ) async throws -> AISetupResult {
        let saved = try settingsStore.load()
        let defaultProvider = saved?.provider ?? .ollama
        guard let provider = await prompt.chooseProvider(defaultProvider: defaultProvider) else {
            throw AISetupError.cancelled
        }

        let descriptor = registry.descriptor(for: provider)
        let baseURL = try await collectValue(
            promptText: provider == .ollama ? "Ollama base URL" : "Base URL",
            envKey: descriptor.baseURLEnvironmentKey,
            savedValue: saved?.provider == provider ? saved?.baseURL : nil,
            defaultValue: descriptor.defaultBaseURL,
            environment: environment
        )
        let model = try await collectValue(
            promptText: "Model",
            envKey: descriptor.modelEnvironmentKey,
            savedValue: saved?.provider == provider ? saved?.model : nil,
            defaultValue: descriptor.defaultModel,
            environment: environment
        )

        let configuration = AIProviderConfiguration(provider: provider, baseURL: baseURL, model: model)

        if provider == .ollama {
            guard let _ = await prompt.askBool(prompt: "Validate connection now?", defaultValue: true) else {
                throw AISetupError.invalidSelection
            }
        }

        let shouldPersist: Bool
        if persistPrompt {
            guard let answer = await prompt.askBool(prompt: "Save these settings for future sessions?", defaultValue: true) else {
                throw AISetupError.invalidSelection
            }
            shouldPersist = answer
        } else {
            shouldPersist = false
        }

        return AISetupResult(configuration: configuration, shouldPersist: shouldPersist)
    }

    private func collectValue(
        promptText: String,
        envKey: String?,
        savedValue: String?,
        defaultValue: String?,
        environment: [String: String]
    ) async throws -> String? {
        let effectiveDefault = envKey.flatMap { normalizedEnvironmentValue(environment[$0]) } ?? savedValue ?? defaultValue
        let answer = await prompt.askString(prompt: promptText, defaultValue: effectiveDefault)
        if envKey == nil, defaultValue == nil {
            return nil
        }
        return answer
    }
}
