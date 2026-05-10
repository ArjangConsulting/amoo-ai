import Foundation
import MCPServer

public let defaultOllamaBaseURL = "http://localhost:11434"
public let defaultOllamaModel = "qwen3.6:latest"
public let defaultAITimeoutSeconds = 600

let amooAIProviderEnvironmentKey = "AMOO_AI_PROVIDER"
let legacyAIProviderEnvironmentKey = "MOBILE_TESTING_AI_PROVIDER"
let amooAIBaseURLEnvironmentKey = "AMOO_AI_BASE_URL"
let amooOllamaBaseURLEnvironmentKey = "AMOO_AI_OLLAMA_BASE_URL"
let legacyOllamaBaseURLEnvironmentKey = "MOBILE_TESTING_AI_OLLAMA_BASE_URL"
let amooAIModelEnvironmentKey = "AMOO_AI_MODEL"
let amooOllamaModelEnvironmentKey = "AMOO_AI_OLLAMA_MODEL"
let legacyOllamaModelEnvironmentKey = "MOBILE_TESTING_AI_OLLAMA_MODEL"
let amooAITimeoutEnvironmentKey = "AMOO_AI_TIMEOUT"

public enum AIProviderKind: String, Sendable, Codable, CaseIterable {
    case disabled
    case local
    case ollama
}

public struct AIProviderConfiguration: Sendable, Equatable, Codable {
    public var provider: AIProviderKind
    public var baseURL: String?
    public var model: String?
    public var timeoutSeconds: Int?

    public init(provider: AIProviderKind, baseURL: String? = nil, model: String? = nil, timeoutSeconds: Int? = nil) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ResolvedAIConfiguration: Sendable, Equatable {
    public var provider: AIProviderKind
    public var baseURL: String?
    public var model: String?
    public var timeoutSeconds: Int?
    public var source: String

    public init(
        provider: AIProviderKind,
        baseURL: String? = nil,
        model: String? = nil,
        timeoutSeconds: Int? = nil,
        source: String
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
        self.source = source
    }

    public var summary: String {
        switch provider {
        case .disabled:
            "disabled"
        case .local:
            "local deterministic fallback"
        case .ollama:
            "Ollama (\(model ?? defaultOllamaModel) @ \(baseURL ?? defaultOllamaBaseURL), timeout \(timeoutSeconds ?? defaultAITimeoutSeconds)s)"
        }
    }
}

public struct AIProviderDescriptor: Sendable {
    let kind: AIProviderKind
    let displayName: String
    let defaultBaseURL: String?
    let defaultModel: String?
    let baseURLEnvironmentKey: String?
    let modelEnvironmentKey: String?
    let buildProvider: @Sendable (ResolvedAIConfiguration) -> (any AIProvider)?

    public init(
        kind: AIProviderKind,
        displayName: String,
        defaultBaseURL: String?,
        defaultModel: String?,
        baseURLEnvironmentKey: String?,
        modelEnvironmentKey: String?,
        buildProvider: @escaping @Sendable (ResolvedAIConfiguration) -> (any AIProvider)?
    ) {
        self.kind = kind
        self.displayName = displayName
        self.defaultBaseURL = defaultBaseURL
        self.defaultModel = defaultModel
        self.baseURLEnvironmentKey = baseURLEnvironmentKey
        self.modelEnvironmentKey = modelEnvironmentKey
        self.buildProvider = buildProvider
    }
}

public struct AIProviderRegistry: Sendable {
    let descriptors: [AIProviderKind: AIProviderDescriptor]

    public init(descriptors: [AIProviderDescriptor] = [
        AIProviderDescriptor(
            kind: .disabled,
            displayName: "Disabled",
            defaultBaseURL: nil,
            defaultModel: nil,
            baseURLEnvironmentKey: nil,
            modelEnvironmentKey: nil,
            buildProvider: { _ in nil }
        ),
        AIProviderDescriptor(
            kind: .local,
            displayName: "Local deterministic fallback",
            defaultBaseURL: nil,
            defaultModel: nil,
            baseURLEnvironmentKey: nil,
            modelEnvironmentKey: nil,
            buildProvider: { _ in LocalAIProvider() }
        ),
        AIProviderDescriptor(
            kind: .ollama,
            displayName: "Ollama",
            defaultBaseURL: defaultOllamaBaseURL,
            defaultModel: defaultOllamaModel,
            baseURLEnvironmentKey: "AMOO_AI_BASE_URL",
            modelEnvironmentKey: "AMOO_AI_MODEL",
            buildProvider: { configuration in
                OllamaProvider(
                    baseURL: configuration.baseURL ?? defaultOllamaBaseURL,
                    model: configuration.model ?? defaultOllamaModel,
                    requestTimeout: TimeInterval(configuration.timeoutSeconds ?? defaultAITimeoutSeconds)
                )
            }
        )
    ]) {
        self.descriptors = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.kind, $0) })
    }

    func descriptor(for kind: AIProviderKind) -> AIProviderDescriptor {
        descriptors[kind] ?? descriptors[.disabled]!
    }

    func makeProvider(from configuration: ResolvedAIConfiguration) -> (any AIProvider)? {
        descriptor(for: configuration.provider).buildProvider(configuration)
    }
}

public protocol AISettingsStore: Sendable {
    func load() throws -> AIProviderConfiguration?
    func save(_ configuration: AIProviderConfiguration) throws
    func reset() throws
}

public struct FileAISettingsStore: AISettingsStore {
    private let configURL: URL

    public init(
        configURL: URL? = nil
    ) {
        if let configURL {
            self.configURL = configURL
        } else {
            let appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/amoo", isDirectory: true)
            self.configURL = appSupport.appendingPathComponent("ai-settings.json")
        }
    }

    public func load() throws -> AIProviderConfiguration? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(AIProviderConfiguration.self, from: data)
    }

    public func save(_ configuration: AIProviderConfiguration) throws {
        let directory = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configURL, options: .atomic)
    }

    public func reset() throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        try FileManager.default.removeItem(at: configURL)
    }

    public var path: String { configURL.path }
}

public struct AIConfigurationResolver: Sendable {
    let registry: AIProviderRegistry
    let settingsStore: any AISettingsStore

    public init(
        registry: AIProviderRegistry = AIProviderRegistry(),
        settingsStore: any AISettingsStore = FileAISettingsStore()
    ) {
        self.registry = registry
        self.settingsStore = settingsStore
    }

    func resolve(
        oneTimeConfiguration: AIProviderConfiguration? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedAIConfiguration {
        if let oneTimeConfiguration {
            return normalize(oneTimeConfiguration, source: "one-time setup")
        }

        if let envConfiguration = environmentConfiguration(environment: environment) {
            return normalize(envConfiguration, source: "environment")
        }

        if let saved = try settingsStore.load() {
            return normalize(saved, source: "saved settings")
        }

        return ResolvedAIConfiguration(provider: .disabled, source: "default")
    }

    private func environmentConfiguration(environment: [String: String]) -> AIProviderConfiguration? {
        let providerValue = firstEnvironmentValue(
            environment,
            keys: [amooAIProviderEnvironmentKey, legacyAIProviderEnvironmentKey]
        )?.lowercased()
        let explicitProvider = providerValue.flatMap { mapProvider($0) }
        let timeoutSeconds = parseTimeoutSeconds(environment: environment)

        if let explicitProvider {
            let descriptor = registry.descriptor(for: explicitProvider)
            return AIProviderConfiguration(
                provider: explicitProvider,
                baseURL: environmentValue(for: descriptor.baseURLEnvironmentKey, environment: environment),
                model: environmentValue(for: descriptor.modelEnvironmentKey, environment: environment),
                timeoutSeconds: timeoutSeconds
            )
        }

        let ollamaDescriptor = registry.descriptor(for: .ollama)
        let hasOllamaOverrides = environmentValue(for: ollamaDescriptor.baseURLEnvironmentKey, environment: environment) != nil ||
            environmentValue(for: ollamaDescriptor.modelEnvironmentKey, environment: environment) != nil ||
            timeoutSeconds != nil

        if hasOllamaOverrides {
            return AIProviderConfiguration(
                provider: .ollama,
                baseURL: environmentValue(for: ollamaDescriptor.baseURLEnvironmentKey, environment: environment),
                model: environmentValue(for: ollamaDescriptor.modelEnvironmentKey, environment: environment),
                timeoutSeconds: timeoutSeconds
            )
        }

        return nil
    }

    private func normalize(_ configuration: AIProviderConfiguration, source: String) -> ResolvedAIConfiguration {
        let descriptor = registry.descriptor(for: configuration.provider)
        return ResolvedAIConfiguration(
            provider: configuration.provider,
            baseURL: normalizedEnvironmentValue(configuration.baseURL) ?? descriptor.defaultBaseURL,
            model: normalizedEnvironmentValue(configuration.model) ?? descriptor.defaultModel,
            timeoutSeconds: configuration.timeoutSeconds ?? defaultAITimeoutSeconds,
            source: source
        )
    }

    private func mapProvider(_ value: String) -> AIProviderKind? {
        switch value {
        case "", "none", "off", "disabled":
            .disabled
        case "local":
            .local
        case "ollama":
            .ollama
        default:
            nil
        }
    }
}

func environmentValue(for key: String?, environment: [String: String]) -> String? {
    guard let key else { return nil }

    switch key {
    case amooAIBaseURLEnvironmentKey:
        return firstEnvironmentValue(environment, keys: [
            amooAIBaseURLEnvironmentKey,
            amooOllamaBaseURLEnvironmentKey,
            legacyOllamaBaseURLEnvironmentKey
        ])
    case amooAIModelEnvironmentKey:
        return firstEnvironmentValue(environment, keys: [
            amooAIModelEnvironmentKey,
            amooOllamaModelEnvironmentKey,
            legacyOllamaModelEnvironmentKey
        ])
    default:
        return normalizedEnvironmentValue(environment[key])
    }
}

func firstEnvironmentValue(_ environment: [String: String], keys: [String]) -> String? {
    for key in keys {
        if let value = normalizedEnvironmentValue(environment[key]) {
            return value
        }
    }

    return nil
}

func parseTimeoutSeconds(environment: [String: String]) -> Int? {
    guard let value = firstEnvironmentValue(environment, keys: [amooAITimeoutEnvironmentKey]) else {
        return nil
    }

    guard let parsed = Int(value), parsed > 0 else {
        return nil
    }

    return parsed
}

func makeAIProvider(
    resolver: AIConfigurationResolver = AIConfigurationResolver(),
    oneTimeConfiguration: AIProviderConfiguration? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> (configuration: ResolvedAIConfiguration, provider: (any AIProvider)?) {
    let resolved = try resolver.resolve(oneTimeConfiguration: oneTimeConfiguration, environment: environment)
    return (resolved, resolver.registry.makeProvider(from: resolved))
}

func resolveAIProviderConfiguration(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    settingsStore: any AISettingsStore = FileAISettingsStore()
) -> ResolvedAIConfiguration {
    let resolver = AIConfigurationResolver(settingsStore: settingsStore)
    return (try? resolver.resolve(environment: environment)) ?? ResolvedAIConfiguration(provider: .disabled, source: "default")
}

func normalizedEnvironmentValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
