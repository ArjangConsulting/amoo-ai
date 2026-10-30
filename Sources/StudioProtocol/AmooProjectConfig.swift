import Foundation

/// The checked-in `amoo.config.json` of a project: named credential profiles an agent can sign in
/// with by reference, never by value. Found by walking up from the working directory to the
/// repository root, like `amoo.md`, and layered the way nested `AGENTS.md` files are: every config on
/// the way up applies and the nearer one wins. A project without one behaves exactly as before.
public struct AmooProjectConfig: Codable, Equatable, Sendable {
    public static let fileName = "amoo.config.json"
    public static let supportedVersion = 1

    public var version: Int
    public var profiles: [String: CredentialProfile]

    public init(version: Int = supportedVersion, profiles: [String: CredentialProfile] = [:]) {
        self.version = version
        self.profiles = profiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        profiles = try container.decodeIfPresent([String: CredentialProfile].self, forKey: .profiles) ?? [:]
    }

    /// The nearest `amoo.config.json` at or above `directory`, stopping at the repository root.
    public static func discover(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        discoverAll(from: directory).first
    }

    /// Every `amoo.config.json` from `directory` up to the repository root, nearest first. An
    /// orchestrator keeps shared profiles at its root and a platform repository adds or overrides its own.
    public static func discoverAll(
        from directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> [URL] {
        var files: [URL] = []
        var root = directory.standardizedFileURL
        while true {
            let file = root.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: file.path) {
                files.append(file)
            }
            if RepositoryTestProfile.isRepositoryBoundary(root) || root.path == "/" {
                return files
            }
            root = root.deletingLastPathComponent()
        }
    }

    /// Loads each file, which must be valid on its own, and layers them. `files` is nearest first.
    public static func load(layers files: [URL]) throws -> Self {
        var merged: Self?
        for file in files.reversed() {
            let config = try load(file)
            merged = merged.map { $0.overlaid(by: config) } ?? config
        }
        guard let merged else { throw AmooProjectConfigError(file: fileName, problem: "no config file given") }
        return merged
    }

    /// `inner` wins: profiles and their fields merge by name, a profile's `apps` list is replaced, and
    /// its launch requirements merge by key.
    func overlaid(by inner: Self) -> Self {
        var result = self
        for (name, profile) in inner.profiles {
            guard let outer = result.profiles[name] else {
                result.profiles[name] = profile
                continue
            }
            result.profiles[name] = CredentialProfile(
                apps: profile.apps,
                requiresLaunchEnv: outer.requiresLaunchEnv.merging(profile.requiresLaunchEnv) { _, new in new },
                fields: outer.fields.merging(profile.fields) { _, new in new }
            )
        }
        return result
    }

    /// Decodes and validates a config file. Errors name the file and the offending entry.
    public static func load(_ file: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw AmooProjectConfigError(file: file.path, problem: "cannot be read: \(error.localizedDescription)")
        }
        let config: Self
        do {
            config = try JSONDecoder().decode(Self.self, from: data)
        } catch let error as AmooProjectConfigError {
            throw AmooProjectConfigError(file: file.path, problem: error.problem)
        } catch {
            throw AmooProjectConfigError(file: file.path, problem: "invalid: \(describe(error))")
        }
        let problems = config.validationProblems()
        guard problems.isEmpty else {
            throw AmooProjectConfigError(file: file.path, problem: problems.joined(separator: "; "))
        }
        return config
    }

    /// Every problem in the config, empty when it is valid.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if version != Self.supportedVersion {
            problems.append("version \(version) is not supported (expected \(Self.supportedVersion))")
        }
        for (name, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            if name.isEmpty || name.contains("#") {
                problems.append("profile name '\(name)' must be non-empty and must not contain '#'")
            }
            if profile.apps.isEmpty {
                problems.append("profile '\(name)' lists no apps")
            }
            if profile.fields.isEmpty {
                problems.append("profile '\(name)' has no fields")
            }
            for (field, credential) in profile.fields.sorted(by: { $0.key < $1.key }) {
                if field.isEmpty || field.contains("#") {
                    problems.append("profile '\(name)' field '\(field)' must be non-empty and must not contain '#'")
                }
                if case let .keychain(service, account) = credential.source, service.isEmpty || account.isEmpty {
                    problems.append("profile '\(name)' field '\(field)' needs a keychain service and account")
                }
            }
        }
        return problems
    }

    private static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case let .keyNotFound(key, context):
            return "missing '\(key.stringValue)' at \(path(context))"
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let keys = context.codingPath.map(\.stringValue)
        return keys.isEmpty ? "the top level" : keys.joined(separator: ".")
    }
}

/// A named account an agent may sign in with, and the apps and launch environment it is allowed for.
public struct CredentialProfile: Codable, Equatable, Sendable {
    /// Bundle or package ids this profile may be typed into.
    public var apps: [String]
    /// Launch environment amoo must have sent to the app. `*` means the key only has to be present.
    public var requiresLaunchEnv: [String: String]
    public var fields: [String: CredentialField]

    enum CodingKeys: String, CodingKey {
        case apps, fields
        case requiresLaunchEnv = "requires_launch_env"
    }

    public init(apps: [String], requiresLaunchEnv: [String: String] = [:], fields: [String: CredentialField]) {
        self.apps = apps
        self.requiresLaunchEnv = requiresLaunchEnv
        self.fields = fields
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decode([String].self, forKey: .apps)
        requiresLaunchEnv = try container.decodeIfPresent([String: String].self, forKey: .requiresLaunchEnv) ?? [:]
        fields = try container.decode([String: CredentialField].self, forKey: .fields)
    }

    /// The launch-environment keys that `environment` does not satisfy, sorted.
    public func unmetLaunchRequirements(_ environment: [String: String]) -> [String] {
        requiresLaunchEnv.compactMap { key, expected in
            guard let actual = environment[key] else { return key }
            return expected == "*" || expected == actual ? nil : key
        }
        .sorted()
    }
}

/// One value of a profile and where it comes from.
public struct CredentialField: Codable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A non-secret value checked into the config, such as a mock account's password.
        case literal(String)
        /// A generic-password item in the user's keychain.
        case keychain(service: String, account: String)
    }

    /// `secret` values may only fill a secure text field and are scrubbed from every amoo output.
    public enum Class: String, Codable, Sendable {
        case identifier, secret
    }

    public var source: Source
    public var fieldClass: Class

    public init(source: Source, fieldClass: Class) {
        self.source = source
        self.fieldClass = fieldClass
    }

    enum CodingKeys: String, CodingKey {
        case literal, keychain
        case fieldClass = "class"
    }

    struct KeychainItem: Codable, Equatable {
        var service: String
        var account: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fieldClass = try container.decode(Class.self, forKey: .fieldClass)
        let literal = try container.decodeIfPresent(String.self, forKey: .literal)
        let keychain = try container.decodeIfPresent(KeychainItem.self, forKey: .keychain)
        switch (literal, keychain) {
        case let (value?, nil):
            source = .literal(value)
        case let (nil, item?):
            source = .keychain(service: item.service, account: item.account)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "a field needs exactly one of 'literal' or 'keychain'"
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fieldClass, forKey: .fieldClass)
        switch source {
        case let .literal(value):
            try container.encode(value, forKey: .literal)
        case let .keychain(service, account):
            try container.encode(KeychainItem(service: service, account: account), forKey: .keychain)
        }
    }
}

public struct AmooProjectConfigError: Error, CustomStringConvertible, Equatable {
    public var file: String
    public var problem: String

    public var description: String {
        "\(file): \(problem)"
    }
}
