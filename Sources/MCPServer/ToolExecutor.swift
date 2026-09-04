import AmooCore
import AuditEngine
import Foundation
import MCP
import ProcessRunner
import TestSession

public protocol ToolExecutor: Sendable {
    func execute(toolName: String, arguments: [String: String]) async -> ToolResult
}

public actor DriverToolExecutor: ToolExecutor {
    /// The default driver used when a tool call does not specify a `session_id`.
    /// Kept for backward compatibility with the original `amoo mcp serve` flow.
    let defaultDriver: any PlatformDriver
    let sessionManager: SessionManager?
    /// Probes for a concurrent `xcodebuild`/`xctest` that amoo did not start, so `start_session`
    /// and `device_install_app` can warn the caller that an install may race or be killed.
    /// Defaults to `.disabled` so unit tests stay hermetic; `amoo mcp serve` / `amoo device`
    /// pass a live one.
    let foreignBuildDetector: ForeignBuildDetector

    public init(
        driver: any PlatformDriver,
        sessionManager: SessionManager? = nil,
        foreignBuildDetector: ForeignBuildDetector = .disabled
    ) {
        defaultDriver = driver
        self.sessionManager = sessionManager
        self.foreignBuildDetector = foreignBuildDetector
    }

    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        let clock = ContinuousClock()
        let start = clock.now
        let result: ToolResult
        do {
            result = try await dispatch(toolName: toolName, arguments: arguments)
        } catch {
            result = .error("\(toolName) failed: \(error)")
        }
        await recordIfNeeded(toolName: toolName, arguments: arguments, result: result)
        let category = toolName == "get_view_hierarchy" ? "hierarchy_retrieval" : "action_execution"
        PerformanceTelemetry.record(
            category,
            operation: toolName,
            duration: start.duration(to: clock.now),
            metadata: ["success": String(!result.isError)]
        )
        return result
    }

    /// Resolve the driver to use for a tool call. Routes to a session driver
    /// when `session_id` is present and active; otherwise falls back to the
    /// default driver.
    func resolveDriver(arguments: [String: String]) async -> any PlatformDriver {
        if let sessionID = arguments["session_id"],
           let manager = sessionManager,
           let session = await manager.session(sessionID),
           await session.isActive {
            return session.driver
        }
        return defaultDriver
    }

    /// amoo's own session / codegen lifecycle tools. A call to one is not an application test step,
    /// so it must never enter a session's recorded action history — otherwise `compile_session_to_plan`
    /// (which runs while the session is still active) records *itself*, and the compiler then has to
    /// carry it as a dropped step and the generator emits a trailing `XCTFail` for it.
    static let controlPlaneTools: Set<String> = [
        "start_session", "start_test_session", "end_session", "end_test_session",
        "list_sessions", "get_session_report", "compile_session_to_plan"
    ]

    private func recordIfNeeded(
        toolName: String,
        arguments: [String: String],
        result: ToolResult
    ) async {
        guard Self.controlPlaneTools.contains(toolName) == false else { return }
        guard let sessionID = arguments["session_id"],
              let manager = sessionManager,
              let session = await manager.session(sessionID),
              await session.isActive
        else { return }

        let action = SessionAction(
            timestamp: Date(),
            toolName: toolName,
            arguments: redactArguments(toolName: toolName, arguments: arguments),
            result: result.content,
            isError: result.isError,
            intent: sessionIntent(toolName: toolName, isError: result.isError),
            observedElements: result.observedElements
        )
        await session.record(action)
        // Persist so a mid-session crash or a server restart still leaves a compilable history
        // behind. The manager batches the actual writes — see `SessionManager.persist`.
        await manager.persist(sessionID)
    }

    private func sessionIntent(toolName: String, isError: Bool) -> SessionAction.Intent {
        if isError {
            return .failedProbe
        }
        if ["assert_visible", "assert_absent", "assert_value", "assert_enabled"].contains(toolName) {
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

    /// Strip out sensitive fields before persisting an action to session history.
    /// Mirrors the existing tool-level redaction in `type_text`.
    private func redactArguments(toolName: String, arguments: [String: String]) -> [String: String] {
        var copy = arguments
        switch toolName {
        case "type_text":
            if let value = copy["text"] {
                copy["text"] = "<redacted, \(value.count) chars>"
            }
        case "fill_field", "set_text":
            if let value = copy["value"] {
                copy["value"] = "<redacted, \(value.count) chars>"
            }
        case "assert_value":
            copy["expected"] = copy["expected"].map { "<redacted, \($0.count) chars>" }
            copy["contains"] = copy["contains"].map { "<redacted, \($0.count) chars>" }
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

func hierarchySummary(_ root: ViewNode) -> (nodes: Int, interactable: Int) {
    var nodes = 0
    var interactable = 0
    var stack = [root]
    while let node = stack.popLast() {
        nodes += 1
        if node.isVisible, node.isEnabled, !node.id.isEmpty || !node.label.isEmpty {
            interactable += 1
        }
        stack.append(contentsOf: node.children)
    }
    return (nodes, interactable)
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

    let typeStr = node.type.map { colored("[\($0.rawValue)]", .cyan) } ?? colored("[other]", .gray)
    let labelStr = node.label.isEmpty ? "" : " \(colored("\"\(node.label)\"", .yellow))"
    let valueStr = node.value.map { " = \(colored($0, .magenta))" } ?? ""
    let idStr = node.id.isEmpty ? "" : " \(colored("id=\(node.id)", .blue))"
    let stateStr: String = {
        if !node.isEnabled {
            return " \(colored("(disabled)", .red))"
        }
        if !node.isVisible {
            return " \(colored("(hidden)", .gray))"
        }
        return ""
    }()

    parts.append("\(prefix)\(typeStr)\(labelStr)\(valueStr)\(idStr)\(stateStr)")

    for child in node.children {
        parts.append(renderViewNode(child, indent: indent + 1))
    }

    return parts.joined(separator: "\n")
}
