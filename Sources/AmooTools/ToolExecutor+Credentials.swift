import AmooLogging
import Foundation
import StudioProtocol

private let logger = AmooLogger.forType(CredentialResolver.self)

extension DriverToolExecutor {
    /// The argument a credential's value replaces, or `nil` for a tool that does not take one.
    static func credentialValueKey(_ tool: String) -> String? {
        switch tool {
        case "type_text": "text"
        case "set_text", "fill_field": "value"
        default: nil
        }
    }

    /// Resolves `credential` and returns the arguments with its value in place of `text`/`value`.
    /// A secret is registered for scrubbing before it is ever dispatched.
    func substitutingCredential(
        _ raw: String,
        toolName: String,
        arguments: [String: String]
    ) async throws -> ([String: String], CredentialField.Class) {
        guard let key = Self.credentialValueKey(toolName) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "credential is accepted only by type_text, set_text and fill_field."
            )
        }
        guard arguments[key] == nil else {
            throw ToolExecutionError(code: "invalid_argument", message: "Pass either \(key) or credential, not both.")
        }
        guard arguments["record_value"] == nil else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "record_value cannot be combined with credential; credential values are never recorded."
            )
        }
        let reference = try CredentialReference(parsing: raw)
        let launch = await credentialLaunch(sessionID: arguments["session_id"])
        logger.info(
            "Resolving credential",
            context: "action=resolve tool=\(toolName) reference=\(reference) app=\(launch?.appID ?? "none")"
        )
        let resolved: ResolvedCredential
        do {
            resolved = try await credentialResolver.resolve(reference, launch: launch)
        } catch let error as ToolExecutionError {
            logger.error(
                "Credential refused",
                error: error,
                context: "action=resolve tool=\(toolName) reference=\(reference) code=\(error.code)"
            )
            throw error
        }
        if resolved.fieldClass == .secret {
            credentialRedactor.register(resolved.value)
            if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
                await session.registerSecret(resolved.value)
            }
        }
        logger.info(
            "Resolved credential",
            context: "action=resolve tool=\(toolName) reference=\(reference) class=\(resolved.fieldClass.rawValue)"
        )
        var copy = arguments
        copy[key] = resolved.value
        return (copy, resolved.fieldClass)
    }

    /// The arguments a call runs with: a `credential` resolved into `text`/`value`, and every
    /// sensitive value registered with the session so its report is scrubbed.
    func preparedArguments(
        toolName: String,
        arguments: [String: String]
    ) async throws -> ([String: String], CredentialField.Class?) {
        var prepared = arguments
        var credentialClass: CredentialField.Class?
        if let reference = arguments["credential"] {
            (prepared, credentialClass) = try await substitutingCredential(
                reference, toolName: toolName, arguments: arguments
            )
        }
        if let id = prepared["session_id"], let session = await sessionManager?.session(id),
           prepared["record_value"] != "fixture" {
            for key in Self.sensitiveArgumentKeys(toolName) {
                if let value = prepared[key] {
                    await session.registerSecret(value)
                }
            }
        }
        return (prepared, credentialClass)
    }

    /// A recorded credential step keeps its reference name, never its value or length.
    static func credentialRecordedArguments(_ arguments: [String: String]) -> [String: String] {
        var copy = arguments
        for key in ["text", "value"] where copy[key] != nil {
            copy[key] = "<redacted, credential>"
        }
        return copy
    }

    /// The launch a credential is checked against: the last `device_launch_app` amoo performed for
    /// this session (or this executor without one), else the session's own start.
    func credentialLaunch(sessionID: String?) async -> CredentialLaunch? {
        if let launch = credentialLaunches[sessionID ?? Self.defaultLaunchKey] {
            return launch
        }
        guard let sessionID, let session = await sessionManager?.session(sessionID), !session.appID.isEmpty else {
            return nil
        }
        return CredentialLaunch(appID: session.appID, environment: session.launchEnvironment)
    }

    /// Records a successful `device_launch_app` so a later credential is checked against it.
    func noteLaunch(toolName: String, arguments: [String: String], result: ToolResult) {
        guard toolName == "device_launch_app", !result.isError, let appID = arguments["app_id"] else { return }
        credentialLaunches[arguments["session_id"] ?? Self.defaultLaunchKey] = CredentialLaunch(
            appID: appID,
            environment: Self.parseEnvironment(arguments["environment"])
        )
    }

    /// Seeds the launch record of a process that did not launch the app itself (`amoo device`).
    public func recordCredentialLaunch(appID: String, environment: [String: String]) {
        credentialLaunches[Self.defaultLaunchKey] = CredentialLaunch(appID: appID, environment: environment)
    }

    /// The launch this executor recorded without a session, for `amoo device` to persist.
    public func lastCredentialLaunch() -> (appID: String, environment: [String: String])? {
        credentialLaunches[Self.defaultLaunchKey].map { ($0.appID, $0.environment) }
    }

    static let defaultLaunchKey = "default"
}
