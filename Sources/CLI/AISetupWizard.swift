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

        let prompt = "Provider [\(defaultText)]: "
        guard let value = readLineWithPrompt(prompt) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = trimmed.isEmpty ? defaultText : trimmed
        if trimmed.isEmpty {
            rewritePrompt(prompt: prompt, answer: choice)
        }

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
            if let defaultValue {
                rewritePrompt(prompt: rendered, answer: defaultValue)
            }
            return defaultValue
        }
        return trimmed
    }

    public func askBool(prompt: String, defaultValue: Bool) async -> Bool? {
        let rendered = "\(prompt) [\(defaultValue ? "Y/n" : "y/N")]: "
        guard let value = readLineWithPrompt(rendered) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            rewritePrompt(prompt: rendered, answer: defaultValue ? "Y" : "N")
            return defaultValue
        }
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

    private func rewritePrompt(prompt: String, answer: String) {
        Swift.print("\u{001B}[1A\r\u{001B}[2K\(prompt)\(answer)")
        fflush(stdout)
    }
}

public struct AISetupResult: Sendable, Equatable {
    var configuration: AIProviderConfiguration
    var shouldPersist: Bool
}

public enum AISetupError: Error, CustomStringConvertible {
    case cancelled
    case invalidSelection
    case validationFailed(String)

    public var description: String {
        switch self {
        case .cancelled:
            "AI setup cancelled."
        case .invalidSelection:
            "Invalid setup selection. Please try again."
        case let .validationFailed(message):
            message
        }
    }
}

public struct AISetupWizard: Sendable {
    let prompt: any AISetupPrompting
    let registry: AIProviderRegistry
    let settingsStore: any AISettingsStore
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        prompt: any AISetupPrompting = ConsoleAISetupPrompter(),
        registry: AIProviderRegistry = AIProviderRegistry(),
        settingsStore: any AISettingsStore = FileAISettingsStore(),
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.prompt = prompt
        self.registry = registry
        self.settingsStore = settingsStore
        self.transport = transport
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
        let timeoutSeconds = try await collectTimeoutSeconds(
            provider: provider,
            savedValue: saved?.provider == provider ? saved?.timeoutSeconds : nil,
            environment: environment
        )

        let configuration = AIProviderConfiguration(
            provider: provider,
            baseURL: baseURL,
            model: model,
            timeoutSeconds: timeoutSeconds
        )

        if provider == .ollama {
            guard let shouldValidate = await prompt.askBool(prompt: "Validate connection now?", defaultValue: true) else {
                throw AISetupError.invalidSelection
            }
            if shouldValidate {
                do {
                    try await validateOllamaConfiguration(configuration)
                } catch let error as AISetupValidationError {
                    throw AISetupError.validationFailed(error.description)
                } catch {
                    throw AISetupError.validationFailed("AI setup validation failed: \(error)")
                }
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

    private func collectTimeoutSeconds(
        provider: AIProviderKind,
        savedValue: Int?,
        environment: [String: String]
    ) async throws -> Int? {
        guard provider == .ollama else { return nil }

        let effectiveDefault = firstEnvironmentValue(environment, keys: [amooAITimeoutEnvironmentKey])
            .flatMap(Int.init)
            ?? savedValue
            ?? defaultAITimeoutSeconds
        let answer = await prompt.askString(prompt: "Request timeout (seconds)", defaultValue: String(effectiveDefault))
        guard let answer, let timeoutSeconds = Int(answer), timeoutSeconds > 0 else {
            throw AISetupError.validationFailed("Request timeout must be a positive whole number of seconds.")
        }
        return timeoutSeconds
    }

    private func validateOllamaConfiguration(_ configuration: AIProviderConfiguration) async throws {
        let baseURL = configuration.baseURL ?? defaultOllamaBaseURL
        let model = configuration.model ?? defaultOllamaModel
        let models = try await loadOllamaModels(baseURL: baseURL, transport: transport)

        guard models.contains(model) else {
            throw AISetupValidationError.modelMissing(model: model, baseURL: baseURL)
        }
    }
}

enum AISetupValidationError: Error, CustomStringConvertible {
    case modelMissing(model: String, baseURL: String)

    var description: String {
        switch self {
        case let .modelMissing(model, baseURL):
            "AI setup validation failed: model \(model) is not available at \(baseURL)."
        }
    }
}
