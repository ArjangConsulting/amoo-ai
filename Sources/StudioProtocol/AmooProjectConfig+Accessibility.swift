import Foundation

/// The `accessibility` section of `amoo.config.json`: the accessibility checks a project opted in to.
///
/// Nothing is checked unless it is switched on here, and `check_accessibility` takes no selection of
/// its own, so this list is the only thing that decides what a run covers. `checks` are what is
/// evaluated on a screen; `configurations` are the display settings the same checks are repeated
/// under. `amoo init` asks for both.
public struct AccessibilityCheckPolicy: Codable, Equatable, Sendable {
    /// One thing evaluated on the current screen.
    public enum Check: String, CaseIterable, Codable, Sendable {
        case names
        case targetSize = "target_size"
        case contrast
        case textClipping = "text_clipping"
        case textScaling = "text_scaling"
        case traits
        case elementDetection = "element_detection"

        /// What opting in means, for `amoo init` and the docs.
        public var summary: String {
            switch self {
            case .names: "controls and images have a spoken name"
            case .targetSize: "touch targets are large enough"
            case .contrast: "text contrasts with its background"
            case .textClipping: "text is not clipped or truncated"
            case .textScaling: "text follows the system text size"
            case .traits: "roles and traits match the control"
            case .elementDetection: "interactive content is exposed to assistive technology"
            }
        }
    }

    /// A display setting the checks are repeated under, one at a time, after the default pass.
    public enum Configuration: String, CaseIterable, Codable, Sendable {
        case darkMode = "dark_mode"
        case largeText = "large_text"
        case increaseContrast = "increase_contrast"

        public var summary: String {
            switch self {
            case .darkMode: "repeat in dark mode"
            case .largeText: "repeat at the largest text size"
            case .increaseContrast: "repeat with increased contrast"
            }
        }
    }

    /// Opt-in by check name. A name left out is opted out, exactly like `false`.
    public var checks: [String: Bool]
    /// Opt-in by configuration name.
    public var configurations: [String: Bool]

    public init(checks: [String: Bool] = [:], configurations: [String: Bool] = [:]) {
        self.checks = checks
        self.configurations = configurations
    }

    public init(checks: [Check], configurations: [Configuration]) {
        self.checks = Dictionary(uniqueKeysWithValues: Check.allCases.map { ($0.rawValue, checks.contains($0)) })
        self.configurations = Dictionary(uniqueKeysWithValues: Configuration.allCases.map {
            ($0.rawValue, configurations.contains($0))
        })
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checks = try container.decodeIfPresent([String: Bool].self, forKey: .checks) ?? [:]
        configurations = try container.decodeIfPresent([String: Bool].self, forKey: .configurations) ?? [:]
    }

    /// The checks switched on, in the order they are reported.
    public var enabledChecks: [Check] {
        Check.allCases.filter { checks[$0.rawValue] == true }
    }

    /// The configurations switched on, in the order they are run.
    public var enabledConfigurations: [Configuration] {
        Configuration.allCases.filter { configurations[$0.rawValue] == true }
    }

    /// Problems with the section, empty when it is valid. An unknown name is an error rather than
    /// ignored, so a typo cannot silently opt a project out of a check it meant to run.
    public func validationProblems() -> [String] {
        let knownChecks = Set(Check.allCases.map(\.rawValue))
        let knownConfigurations = Set(Configuration.allCases.map(\.rawValue))
        return checks.keys.sorted().filter { !knownChecks.contains($0) }.map {
            "accessibility.checks has no check named '\($0)'"
                + " (expected one of: \(knownChecks.sorted().joined(separator: ", ")))"
        } + configurations.keys.sorted().filter { !knownConfigurations.contains($0) }.map {
            "accessibility.configurations has no configuration named '\($0)'"
                + " (expected one of: \(knownConfigurations.sorted().joined(separator: ", ")))"
        }
    }

    /// `inner` wins name by name, so a platform repository can switch one check off without
    /// restating the orchestrator's list.
    func overlaid(by inner: Self) -> Self {
        Self(
            checks: checks.merging(inner.checks) { _, new in new },
            configurations: configurations.merging(inner.configurations) { _, new in new }
        )
    }
}

/// What `amoo.config.json` says about accessibility checks for one project.
public enum AccessibilityCheckResolution: Equatable, Sendable {
    /// No config file, or no `accessibility` section: the project has not opted in to anything.
    case notConfigured
    /// The config cannot be read. Unlike screenshot defaults this is surfaced, because falling back
    /// would turn a broken file into "nothing to check".
    case invalid(String)
    case configured(AccessibilityCheckPolicy)

    /// The effective section for the project at or above `directory`, layered like the rest of the config.
    public static func resolve(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> Self {
        let files = AmooProjectConfig.discoverAll(from: directory)
        guard !files.isEmpty else { return .notConfigured }
        do {
            let config = try AmooProjectConfig.load(layers: files)
            return config.accessibility.map(Self.configured) ?? .notConfigured
        } catch {
            return .invalid("\(error)")
        }
    }

    /// The policy in effect, or an empty one when the project has not opted in or its config is unreadable.
    public var policy: AccessibilityCheckPolicy {
        if case let .configured(policy) = self {
            return policy
        }
        return AccessibilityCheckPolicy()
    }
}

public extension AmooProjectConfig {
    /// Sets the accessibility checks in the config file at `file`, creating a minimal config when
    /// there is none and keeping every other key.
    static func writeAccessibilityChecks(_ policy: AccessibilityCheckPolicy, to file: URL) throws {
        var config = FileManager.default.fileExists(atPath: file.path) ? try load(file) : Self()
        config.accessibility = policy
        try config.write(to: file)
    }
}
