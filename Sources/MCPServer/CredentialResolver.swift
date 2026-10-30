import Foundation
import MCP
import StudioProtocol
import TestSession

/// `credential="<profile>#<field>"`: the only part of a credential an agent ever handles.
struct CredentialReference: Equatable, Sendable, CustomStringConvertible {
    let profile: String
    let field: String

    init(parsing raw: String) throws {
        let parts = raw.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "credential must look like '<profile>#<field>', for example 'mock-user#password'."
            )
        }
        profile = parts[0]
        field = parts[1]
    }

    var description: String {
        "\(profile)#\(field)"
    }
}

/// Reads a keychain item for a credential field. Failures must map to ``SecretStoreError``.
public protocol SecretStore: Sendable {
    func load(service: String, account: String) async throws -> String
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// The store needs a person to unlock it or to approve this process.
    case locked
    case notFound
    /// This platform or build has no store.
    case unavailable
}

/// The store used when none is configured, so keychain profiles fail closed.
public struct UnavailableSecretStore: SecretStore {
    public init() {}

    public func load(service _: String, account _: String) async throws -> String {
        throw SecretStoreError.unavailable
    }
}

/// The app amoo launched and the environment it launched it with. A profile is checked against
/// this record, never against anything the caller claims.
struct CredentialLaunch: Equatable, Sendable {
    var appID: String
    var environment: [String: String]
}

struct ResolvedCredential: Sendable {
    var reference: CredentialReference
    var value: String
    var fieldClass: CredentialField.Class
}

/// Resolves credential references from the project's `amoo.config.json` at call time.
public struct CredentialResolver: Sendable {
    let locateConfig: @Sendable () -> URL?
    let store: any SecretStore

    public init(
        locateConfig: @escaping @Sendable () -> URL? = { AmooProjectConfig.discover() },
        store: any SecretStore = UnavailableSecretStore()
    ) {
        self.locateConfig = locateConfig
        self.store = store
    }

    func resolve(_ reference: CredentialReference, launch: CredentialLaunch?) async throws -> ResolvedCredential {
        guard let file = locateConfig() else {
            throw Self.blocked(
                "no_credentials",
                "blocked: no credentials. No \(AmooProjectConfig.fileName) was found from the working directory "
                    + "up to the repository root."
            )
        }
        let config: AmooProjectConfig
        do {
            config = try AmooProjectConfig.load(file)
        } catch {
            throw Self.blocked("credential_config_invalid", "blocked: no credentials. \(error)")
        }
        guard let profile = config.profiles[reference.profile] else {
            throw Self.blocked(
                "no_credentials",
                "blocked: no credentials. Profile '\(reference.profile)' is not in \(AmooProjectConfig.fileName)."
            )
        }
        guard let field = profile.fields[reference.field] else {
            throw Self.blocked(
                "no_credentials",
                "blocked: no credentials. Profile '\(reference.profile)' has no field '\(reference.field)'."
            )
        }
        guard let launch else {
            throw Self.blocked(
                "credential_not_allowed",
                "blocked: profile not allowed. amoo has no record of launching the app in this session or runtime, "
                    + "so it cannot check the profile's apps and launch environment. Launch the app through amoo."
            )
        }
        guard profile.apps.contains(launch.appID) else {
            throw Self.blocked(
                "credential_not_allowed",
                "blocked: profile not allowed for \(launch.appID). Profile '\(reference.profile)' is limited to "
                    + profile.apps.sorted().joined(separator: ", ") + "."
            )
        }
        let unmet = profile.unmetLaunchRequirements(launch.environment)
        guard unmet.isEmpty else {
            throw Self.blocked(
                "credential_not_allowed",
                "blocked: profile not allowed for \(launch.appID). amoo launched it without the launch environment "
                    + "profile '\(reference.profile)' requires: \(unmet.joined(separator: ", "))."
            )
        }
        let value: String = switch field.source {
        case let .literal(literal):
            literal
        case let .keychain(service, account):
            try await load(service: service, account: account, reference: reference)
        }
        guard !value.isEmpty else {
            throw Self.blocked("no_credentials", "blocked: no credentials. '\(reference)' resolved to an empty value.")
        }
        return ResolvedCredential(reference: reference, value: value, fieldClass: field.fieldClass)
    }

    private func load(service: String, account: String, reference: CredentialReference) async throws -> String {
        do {
            return try await store.load(service: service, account: account)
        } catch SecretStoreError.notFound {
            throw Self.blocked(
                "no_credentials",
                "blocked: no credentials. The keychain has no item for '\(reference)'."
            )
        } catch SecretStoreError.unavailable {
            throw Self.blocked(
                "credential_store_unavailable",
                "blocked: no credential store on this platform or build for '\(reference)'. "
                    + "Use a profile with literal values, or return this to the caller."
            )
        } catch {
            throw Self.blocked(
                "credential_store_locked",
                "blocked: credential store locked for '\(reference)'. A person must unlock it or approve amoo; "
                    + "return this to the caller and do not retry."
            )
        }
    }

    static func blocked(_ code: String, _ message: String) -> ToolExecutionError {
        ToolExecutionError(code: code, message: message, extra: ["blocked": .bool(true)])
    }
}

/// The class of the credential the current dispatch is typing, so the text tools can refuse a
/// secret where it would be visible. `nil` for every call without a `credential`.
enum CredentialDispatch {
    @TaskLocal static var fieldClass: CredentialField.Class?
}

extension ToolResult {
    /// Replaces every registered secret in the text this result carries back to the caller or into
    /// a recording. Images are pixels and cannot be scrubbed; secrets only fill secure fields for that reason.
    func redacted(using redactor: ArtifactRedactor) -> ToolResult {
        var copy = self
        copy.content = redactor.redact(content)
        copy.recordedContent = recordedContent.map(redactor.redact)
        copy.structuredContent = structuredContent.map { $0.redacted(using: redactor) }
        return copy
    }
}

extension Value {
    func redacted(using redactor: ArtifactRedactor) -> Value {
        switch self {
        case let .string(text):
            .string(redactor.redact(text))
        case let .array(values):
            .array(values.map { $0.redacted(using: redactor) })
        case let .object(fields):
            .object(fields.mapValues { $0.redacted(using: redactor) })
        default:
            self
        }
    }
}
