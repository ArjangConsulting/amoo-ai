import AmooCore
import AuditEngine
import Foundation
import MCP
import ProcessRunner
import StudioProtocol
import SwiftyTerminal
import TestSession
import WebInspector

public protocol ToolExecutor: Sendable {
    func execute(toolName: String, arguments: [String: String]) async -> ToolResult
}

public actor DriverToolExecutor: ToolExecutor {
    /// The default driver used when a tool call does not specify a `session_id`.
    /// Kept for backward compatibility with the original `amoo mcp serve` flow.
    private let operationQueue = DeviceOperationQueue()
    private var defaultDeviceKey: String?
    private let defaultDeviceID: String?
    let defaultDriver: any PlatformDriver
    let sessionManager: SessionManager?
    /// Probes for a concurrent `xcodebuild`/`xctest` that amoo did not start, so `start_session`
    /// and `device_install_app` can warn the caller that an install may race or be killed.
    /// Defaults to `.disabled` so unit tests stay hermetic; `amoo mcp serve` / `amoo device`
    /// pass a live one.
    let foreignBuildDetector: ForeignBuildDetector
    /// Resolves a WebView debugging client for `webview_eval` / `webview_dom`. Defaults to
    /// `UnconfiguredWebInspector` so those tools report "not configured" rather than guess a
    /// transport; `amoo mcp serve` / `amoo device` pass a live resolver.
    let webInspector: any WebInspecting
    /// The platform this executor was started for (`amoo mcp serve --platform`). Tools that take
    /// an optional `platform` argument fall back to it rather than to iOS.
    let defaultPlatform: Platform?
    /// Resolves `credential` references; the default finds `amoo.config.json` and has no keychain.
    let credentialResolver: CredentialResolver
    /// Every secret this executor has resolved, scrubbed from every later result it returns.
    var credentialRedactor = ArtifactRedactor()
    /// The last app amoo launched per session id (`default` without one), for the credential gate.
    var credentialLaunches: [String: CredentialLaunch] = [:]

    public init(
        driver: any PlatformDriver,
        sessionManager: SessionManager? = nil,
        foreignBuildDetector: ForeignBuildDetector = .disabled,
        webInspector: any WebInspecting = UnconfiguredWebInspector(),
        defaultPlatform: Platform? = nil,
        defaultDeviceID: String? = nil,
        credentialResolver: CredentialResolver = CredentialResolver()
    ) {
        self.credentialResolver = credentialResolver
        self.defaultPlatform = defaultPlatform
        self.defaultDeviceID = defaultDeviceID
        if let defaultPlatform, let defaultDeviceID {
            defaultDeviceKey = "\(defaultPlatform.rawValue):\(defaultDeviceID)"
        }
        defaultDriver = driver
        self.sessionManager = sessionManager
        self.foreignBuildDetector = foreignBuildDetector
        self.webInspector = webInspector
    }

    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        if toolName == "end_session", boolArgument(arguments["force"]) == true {
            do { _ = try ToolRequest(name: toolName, arguments: arguments) } catch {
                return await executeOrdered(toolName: toolName, arguments: arguments)
            }
            if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
                await operationQueue.cancel(key: "\(session.platform.rawValue):\(session.deviceID)", owner: id)
            }
            return await executeOrdered(toolName: toolName, arguments: arguments)
        }
        if Self.controlPlaneTools.contains(toolName), toolName != "end_session" {
            return await executeOrdered(toolName: toolName, arguments: arguments)
        }
        let key: String
        if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
            key = "\(session.platform.rawValue):\(session.deviceID)"
        } else if arguments["session_id"] != nil {
            return await executeOrdered(toolName: toolName, arguments: arguments)
        } else {
            if defaultDeviceKey == nil,
               let info = try? await OperationDeadline.read(until: .now + .seconds(2), operation: {
                   try await self.defaultDriver.deviceInfo()
               }) {
                defaultDeviceKey = "\(info.platform.rawValue):\(info.id)"
            }
            key = defaultDeviceKey ?? "default"
        }
        return await operationQueue.run(key: key, owner: arguments["session_id"]) {
            await self.executeOrdered(toolName: toolName, arguments: arguments)
        }
    }

    // swiftlint:disable multiline_arguments
    func executeOrdered(toolName: String, arguments: [String: String]) async -> ToolResult {
        let clock = ContinuousClock()
        let start = clock.now
        var result: ToolResult
        var executionTool = toolName
        var executionArguments = arguments
        var dispatchStarted = false
        var credentialClass: CredentialField.Class?
        do {
            try Task.checkCancellation()
            _ = try ToolRequest(name: toolName, arguments: arguments)
            let callArguments: [String: String]
            (callArguments, credentialClass) = try await preparedArguments(toolName: toolName, arguments: arguments)
            (executionTool, executionArguments) = try await canonicalGesture(tool: toolName, arguments: callArguments)
            executionArguments = try await normalizedCoordinates(tool: executionTool, arguments: executionArguments)
            dispatchStarted = true
            let dispatchTool = executionTool
            let dispatchArguments = executionArguments
            result = try await CredentialDispatch.$fieldClass.withValue(credentialClass) {
                try await self.dispatch(toolName: dispatchTool, arguments: dispatchArguments)
            }
            noteLaunch(toolName: executionTool, arguments: executionArguments, result: result)
        } catch let error as ToolExecutionError {
            result = error.result
        } catch is OperationDeadline.DeadlineExceeded {
            result = executionFailureDiagnostics(
                ToolExecutionError(code: "deadline_exceeded", message: "Operation exceeded its time budget.").result,
                tool: executionTool, started: start, dispatchStarted: dispatchStarted
            )
        } catch is CancellationError {
            result = ToolExecutionError(code: "cancelled", message: "Operation cancelled.").result
        } catch {
            let failure = await ToolResult.error(failureMessage(toolName: toolName, error: error, arguments: arguments))
            result = executionFailureDiagnostics(
                failure, tool: executionTool, started: start, dispatchStarted: dispatchStarted
            )
        }
        result = await diagnoseConnectivityFailure(result, arguments: executionArguments)
        if !credentialRedactor.isEmpty {
            result = result.redacted(using: credentialRedactor)
        }
        await recordIfNeeded(toolName: executionTool, arguments: executionArguments, result: result)
        let category = toolName == "get_view_hierarchy" ? "hierarchy_retrieval" : "action_execution"
        PerformanceTelemetry.record(
            category,
            operation: toolName,
            duration: start.duration(to: clock.now),
            metadata: [
                "success": String(!result.isError),
                "response_text_bytes": String(result.content.utf8.count),
                "image_bytes": String(result.image?.data.count ?? 0),
                "observed_elements": String(result.observedElements.count)
            ]
        )
        return result
    }

    // swiftlint:enable multiline_arguments

    /// A supplied session ID must resolve to an active session; omission alone uses the default.
    func resolveDriver(arguments: [String: String]) async throws -> any PlatformDriver {
        guard let sessionID = arguments["session_id"] else { return defaultDriver }
        guard let manager = sessionManager, let session = await manager.session(sessionID) else {
            throw ToolExecutionError(
                code: "session_not_found",
                message: "Session not found in this MCP server process. Live session IDs cannot attach across"
                    + " server processes or agent contexts using separate servers. Continue in the owning context,"
                    + " or call start_session here on an available device; release the owner's session first"
                    + " if reusing its device. Never drop session_id to bypass this error."
            )
        }
        guard await session.isActive else {
            throw ToolExecutionError(code: "session_closed", message: "Session is closed. Start a new session.")
        }
        return session.driver
    }

    /// amoo's own session / codegen lifecycle tools. A call to one is not an application test step,
    /// so it must never enter a session's recorded action history — otherwise `compile_session_to_plan`
    /// (which runs while the session is still active) records *itself*, and the compiler then has to
    /// carry it as a dropped step and the generator emits a trailing `XCTFail` for it.
    static let controlPlaneTools: Set<String> = [
        "start_session", "start_test_session", "end_session", "end_test_session",
        "list_sessions", "get_session_report", "compile_session_to_plan",
        "companion_warm", "companion_status", "session_startup_status", "reset_companion"
    ]

    private func recordIfNeeded(
        toolName: String,
        arguments: [String: String],
        result: ToolResult
    ) async {
        guard toolName != "run_steps", Self.controlPlaneTools.contains(toolName) == false,
              let sessionID = arguments["session_id"],
              let manager = sessionManager,
              let session = await manager.session(sessionID),
              await session.isActive
        else { return }

        let recordedResult = result.recordedContent ?? result.content
        let action = SessionAction(
            timestamp: Date(),
            toolName: toolName,
            arguments: arguments["credential"] == nil
                ? redactArguments(toolName: toolName, arguments: arguments)
                : Self.credentialRecordedArguments(arguments),
            result: toolName == "open_url" ? "Opened URL (query values redacted)" : recordedResult,
            isError: result.isError,
            intent: sessionIntent(toolName: toolName, isError: result.isError),
            observedElements: result.observedElements,
            diagnosticEvidence: diagnosticEvidence(toolName: toolName, arguments: arguments, result: result)
        )
        await session.record(action)
        // Persist so a mid-session crash or a server restart still leaves a compilable history
        // behind. The manager batches the actual writes — see `SessionManager.persist`.
        await manager.persist(sessionID)
    }

    private func sessionIntent(toolName: String, isError: Bool) -> SessionAction.Intent {
        if Self.diagnosticTools.contains(toolName) {
            return .diagnostic
        }
        // Even a failed journey stays an assertion, so plan compilation reports the blocked export.
        if ["assert_accessibility_journey", "assert_talkback_speech"].contains(toolName) {
            return .assertion
        }
        if isError {
            return .failedProbe
        }
        if [
            "assert_visible",
            "assert_absent",
            "assert_value",
            "assert_enabled",
            "assert_selected",
            "assert_checked",
            "assert_state_description"
        ]
        .contains(toolName) {
            return .assertion
        }
        if [
            "find_elements", "get_view_hierarchy", "get_screen_context", "describe_screen",
            "take_screenshot", "take_screenshot_metadata", "current_app", "list_devices", "list_apps"
        ].contains(toolName) {
            return .diagnostic
        }
        return .testStep
    }

    static func sensitiveArgumentKeys(_ tool: String) -> [String] {
        switch tool {
        case "type_text": ["text"]
        case "set_text", "fill_field": ["value"]
        case "assert_value", "assert_state_description": ["expected", "contains"]
        case "assert_talkback_speech": ["speech"]
        default: []
        }
    }

    /// Strip out sensitive fields before persisting an action to session history.
    /// Mirrors the existing tool-level redaction in `type_text`.
    private func redactArguments(toolName: String, arguments: [String: String]) -> [String: String] {
        var copy = arguments
        guard copy["record_value"] != "fixture" else { return copy }
        switch toolName {
        case "type_text":
            if let value = copy["text"] {
                copy["text"] = "<redacted, \(value.count) chars>"
            }
        case "fill_field", "set_text":
            if let value = copy["value"] {
                copy["value"] = "<redacted, \(value.count) chars>"
            }
        case "assert_value", "assert_state_description":
            copy["expected"] = copy["expected"].map { "<redacted, \($0.count) chars>" }
            copy["contains"] = copy["contains"].map { "<redacted, \($0.count) chars>" }
        case "assert_talkback_speech":
            copy["speech"] = "<speech expectations not retained>"
        case "open_url":
            copy["url"] = copy["url"].map(ArtifactRedactor.redactedURL)
        case "assert_selected", "assert_checked":
            // Recorded explicitly, so a defaulted expectation is never read back as an absent one.
            copy["expected"] = (try? Self.parseExpectedSelection(copy["expected"])).map(String.init) ?? copy["expected"]
        default:
            break
        }
        return copy
    }

    /// Parses `k=v,k2=v2` into a dictionary. Empty entries are skipped.
    /// Parses `KEY=VALUE` pairs separated by newlines or commas.
    ///
    /// Newlines take precedence when present: the CLI joins repeated `--env` flags that way so a
    /// value is free to contain a comma, which the comma form — still accepted, and what MCP
    /// clients send — cannot express.
    /// Resolves the `scope` argument to the process a query should run against.
    ///
    /// `app` keeps each driver's own resolution (the bound app under test, else frontmost).
    /// `system` targets the platform's system UI, which hosts permission alerts and the Sign in
    /// with Apple sheet — neither of which the app under test can see. An explicit `bundle_id`
    /// overrides both.
    func queryScopeAppID(
        arguments: [String: String],
        driver: any PlatformDriver
    ) -> String? {
        if let bundleID = arguments["bundle_id"], !bundleID.isEmpty {
            return bundleID
        }
        switch arguments["scope"]?.lowercased() {
        case "system": return driver.systemUIAppID
        default: return nil
        }
    }

    /// Converts an incoming coordinate pair into the points that gestures take.
    ///
    /// Gestures are in points; screenshots come back in pixels, three times larger on this class
    /// of device. Reading a position off a screenshot and passing it straight through is the
    /// obvious thing to do and silently wrong — the tap lands off-screen and still reports
    /// success. `unit` makes the space explicit instead of leaving it to be inferred.
    func convertToPoints(
        x: Double,
        y: Double,
        unit: String?,
        driver: any PlatformDriver
    ) async throws -> (x: Double, y: Double) {
        switch (unit ?? "points").lowercased() {
        case "points", "point", "pt":
            return (x, y)
        case "pixels", "pixel", "px":
            let screen = try await driver.screenGeometry()
            guard screen.scale > 0 else { return (x, y) }
            return (x / screen.scale, y / screen.scale)
        case "normalized", "fraction":
            let screen = try await driver.screenGeometry()
            return (x * screen.widthPoints, y * screen.heightPoints)
        default:
            throw AmooError.commandFailed(
                command: "unit",
                output: "Unknown unit '\(unit ?? "")'. Use points, pixels, or normalized."
            )
        }
    }

    nonisolated public static func parseEnvironment(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        let separator: Character = raw.contains("\n") ? "\n" : ","
        var result: [String: String] = [:]
        for pair in raw.split(separator: separator) {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let equals = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: equals)...])
                if !key.isEmpty {
                    result[key] = value
                }
            }
        }
        return result
    }
}

/// Counts through `ScreenObservation`, so this agrees with `describe_screen`. It used to count any
/// visible, enabled node with an id — and iOS gives every node one — so every node read as
/// interactable (110 of 110 on a calendar screen with a dozen controls).
func hierarchySummary(_ root: ViewNode) -> (nodes: Int, interactable: Int) {
    let observation = ScreenObservation(hierarchy: root)
    return (observation.elements.count, observation.context.interactableCount)
}

func boolArgument(_ raw: String?) -> Bool? {
    switch raw?.lowercased() {
    case "true", "1", "yes": true
    case "false", "0", "no": false
    default: nil
    }
}

// MARK: - View hierarchy rendering

func renderViewNode(_ node: ViewNode, indent: Int) -> String {
    let prefix = String(repeating: "  ", count: indent)
    var parts: [String] = []

    let typeStr = node.type.map { styled("[\($0.rawValue)]", .cyan) } ?? styled("[other]", .gray)
    let labelStr = node.label.isEmpty ? "" : " \(styled("\"\(node.label)\"", .yellow))"
    let valueStr = node.value.map { " = \(styled($0, .magenta))" } ?? ""
    let idStr = node.id.isEmpty ? "" : " \(styled("id=\(node.id)", .blue))"
    let stateStr: String = {
        if !node.isEnabled {
            return " \(styled("(disabled)", .red))"
        }
        if !node.isVisible {
            return " \(styled("(hidden)", .gray))"
        }
        return ""
    }()

    parts.append("\(prefix)\(typeStr)\(labelStr)\(valueStr)\(idStr)\(stateStr)")

    if let semantics = node.semantics {
        parts.append("\(prefix)  ref=\(semantics.reference) path=\(semantics.hierarchyPath)")
    }
    for child in node.children {
        parts.append(renderViewNode(child, indent: indent + 1))
    }

    return parts.joined(separator: "\n")
}

extension DriverToolExecutor {
    /// `"<tool> failed: <error>"`, except that a timeout on a device someone else is driving is
    /// reported as that — a non-amoo test runner on the same device is the usual cause of an
    /// otherwise opaque "RPC timed out before completing".
    func failureMessage(toolName: String, error: any Error, arguments: [String: String]) async -> String {
        let plain = "\(toolName) failed: \(error)"
        let text = "\(error)".lowercased()
        guard text.contains("timed out") || text.contains("deadlineexceeded") || text.contains("deadline exceeded"),
              let identity = await failureDeviceIdentity(arguments: arguments),
              let hijack = await foreignBuildDetector.hijackMessage(platform: identity.platform, deviceID: identity.id)
        else {
            let snapshotTool = toolName.hasPrefix("assert_") || [
                "find_elements", "get_view_hierarchy", "get_screen_context", "describe_screen",
                "tap", "tap_element", "set_text", "find_element_by_description"
            ].contains(toolName)
            return plain + (snapshotTool ? slowSnapshotHint(for: text) : "")
        }
        return "\(toolName) failed: \(hijack) (original error: \(error))"
    }

    private func failureDeviceIdentity(arguments: [String: String]) async -> (platform: Platform, id: String)? {
        if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
            return (session.platform, session.deviceID)
        }
        if let defaultPlatform, let defaultDeviceID {
            return (defaultPlatform, defaultDeviceID)
        }
        guard let driver = try? await resolveDriver(arguments: arguments),
              let info = try? await OperationDeadline.read(until: .now + .seconds(2), operation: {
                  try await driver.deviceInfo()
              }) else { return nil }
        return (info.platform, info.id)
    }

    /// Explains a deadline the device missed with no one else driving it. The usual cause is an
    /// accessibility snapshot too large to finish in time — an accessibility Dynamic Type size, a
    /// long list, a deep SwiftUI tree — not a wedged companion, so say how to get past it.
    private func slowSnapshotHint(for errorText: String) -> String {
        guard errorText.contains("timed out") || errorText.contains("deadlineexceeded")
            || errorText.contains("deadline exceeded") else { return "" }
        return "\nThe device did not answer in time. If the screen is large or dense (accessibility text sizes,"
            + " long lists), the accessibility snapshot can take longer than the 12s default: scope the next"
            + " query (find_elements with id or parent_id, not an unfiltered one), relaunch the app to"
            + " reset a stuck snapshot, or raise the deadline by starting the MCP server with"
            + " AMOO_RPC_TIMEOUT_SECONDS=<seconds> (1-600)."
    }
}
