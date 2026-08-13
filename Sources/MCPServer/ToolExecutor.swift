import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

public protocol ToolExecutor: Sendable {
    func execute(toolName: String, arguments: [String: String]) async -> ToolResult
}

// swiftlint:disable:next type_body_length
public actor DriverToolExecutor: ToolExecutor {
    /// The default driver used when a tool call does not specify a `session_id`.
    /// Kept for backward compatibility with the original `amoo mcp serve` flow.
    private let defaultDriver: any PlatformDriver
    private let sessionManager: SessionManager?

    public init(driver: any PlatformDriver, sessionManager: SessionManager? = nil) {
        defaultDriver = driver
        self.sessionManager = sessionManager
    }

    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        let result: ToolResult
        do {
            result = try await dispatch(toolName: toolName, arguments: arguments)
        } catch {
            result = .error("\(toolName) failed: \(error)")
        }
        await recordIfNeeded(toolName: toolName, arguments: arguments, result: result)
        return result
    }

    /// Resolve the driver to use for a tool call. Routes to a session driver
    /// when `session_id` is present and active; otherwise falls back to the
    /// default driver.
    private func resolveDriver(arguments: [String: String]) async -> any PlatformDriver {
        if let sessionID = arguments["session_id"],
           let manager = sessionManager,
           let session = await manager.session(sessionID),
           await session.isActive {
            return session.driver
        }
        return defaultDriver
    }

    private func recordIfNeeded(
        toolName: String,
        arguments: [String: String],
        result: ToolResult
    ) async {
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
            isError: result.isError
        )
        await session.record(action)
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
        case "fill_field":
            if let value = copy["value"] {
                copy["value"] = "<redacted, \(value.count) chars>"
            }
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
    private func queryScopeAppID(
        arguments: [String: String],
        driver: any PlatformDriver
    ) -> String? {
        if let bundleID = arguments["bundle_id"], !bundleID.isEmpty { return bundleID }
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
    private func convertToPoints(
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

    public nonisolated static func parseEnvironment(_ raw: String?) -> [String: String] {
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

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func dispatch(toolName: String, arguments: [String: String]) async throws -> ToolResult {
        let driver = await resolveDriver(arguments: arguments)
        switch toolName {
        // Device lifecycle
        case "device_boot":
            try await driver.boot()
            return .success("Device booted")

        case "device_shutdown":
            try await driver.shutdown()
            return .success("Device shut down")

        case "device_install_app":
            guard let path = arguments["path"] else {
                return .error("Missing required argument: path")
            }
            try await driver.installApp(path: path)
            return .success("App installed from \(path)")

        case "device_launch_app":
            guard let appID = arguments["app_id"] else {
                return .error("Missing required argument: app_id")
            }
            let launchArgs: [String] = arguments["launch_args"]
                .map { $0.split(separator: ",").map(String.init) } ?? []
            let env = Self.parseEnvironment(arguments["environment"])
            try await driver.launchApp(appID: appID, arguments: launchArgs, environment: env)
            return .success("App launched: \(appID)")

        case "device_terminate_app":
            guard let appID = arguments["app_id"] else {
                return .error("Missing required argument: app_id")
            }
            try await driver.terminateApp(appID: appID)
            return .success("App terminated: \(appID)")

        case "device_uninstall_app":
            guard let appID = arguments["app_id"] else {
                return .error("Missing required argument: app_id")
            }
            try await driver.uninstallApp(appID: appID)
            return .success("App uninstalled: \(appID)")

        // Touch actions
        case "tap":
            guard let x = arguments["x"].flatMap(Double.init),
                  let y = arguments["y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: x, y (numbers)")
            }
            let point = try await convertToPoints(x: x, y: y, unit: arguments["unit"], driver: driver)
            try await driver.tap(at: Point(x: point.x, y: point.y))
            return .success("Tapped at (\(point.x), \(point.y)) pts")

        case "double_tap":
            guard let x = arguments["x"].flatMap(Double.init),
                  let y = arguments["y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: x, y (numbers)")
            }
            let point = try await convertToPoints(x: x, y: y, unit: arguments["unit"], driver: driver)
            try await driver.doubleTap(at: Point(x: point.x, y: point.y))
            return .success("Double tapped at (\(point.x), \(point.y)) pts")

        case "long_press":
            guard let x = arguments["x"].flatMap(Double.init),
                  let y = arguments["y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: x, y (numbers)")
            }
            let ms = arguments["duration_ms"].flatMap(Int.init) ?? 500
            let point = try await convertToPoints(x: x, y: y, unit: arguments["unit"], driver: driver)
            try await driver.longPress(
                at: Point(x: point.x, y: point.y),
                duration: Duration(milliseconds: ms)
            )
            return .success("Long pressed at (\(point.x), \(point.y)) pts for \(ms)ms")

        // Gesture actions
        case "swipe":
            guard let fromX = arguments["from_x"].flatMap(Double.init),
                  let fromY = arguments["from_y"].flatMap(Double.init),
                  let toX = arguments["to_x"].flatMap(Double.init),
                  let toY = arguments["to_y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: from_x, from_y, to_x, to_y")
            }
            let ms = arguments["duration_ms"].flatMap(Int.init) ?? 300
            let unit = arguments["unit"]
            let start = try await convertToPoints(x: fromX, y: fromY, unit: unit, driver: driver)
            let end = try await convertToPoints(x: toX, y: toY, unit: unit, driver: driver)
            try await driver.swipe(
                from: Point(x: start.x, y: start.y),
                to: Point(x: end.x, y: end.y),
                duration: Duration(milliseconds: ms)
            )
            return .success(
                "Swiped from (\(start.x),\(start.y)) to (\(end.x),\(end.y)) pts"
            )

        case "swipe_in_direction":
            guard let dirStr = arguments["direction"] else {
                return .error("Missing required argument: direction (up|down|left|right)")
            }
            guard let direction = parseDirection(dirStr) else {
                return .error("Invalid direction: \(dirStr). Use up, down, left, or right.")
            }
            let distance = arguments["distance"].flatMap(Double.init) ?? 300
            let ms = arguments["duration_ms"].flatMap(Int.init) ?? 400
            let element: ElementSelector? = if let id = arguments["element_id"] {
                ElementSelector(id: id)
            } else if let label = arguments["element_label"] {
                ElementSelector(label: label)
            } else {
                nil
            }
            try await driver.swipe(
                direction: direction,
                distance: distance,
                duration: Duration(milliseconds: ms),
                element: element
            )
            return .success("Swiped \(dirStr) by \(distance) pts")

        case "scroll":
            guard let dirStr = arguments["direction"] else {
                return .error("Missing required argument: direction (up|down|left|right)")
            }
            guard let direction = parseDirection(dirStr) else {
                return .error("Invalid direction: \(dirStr). Use up, down, left, or right.")
            }
            let distance = arguments["distance"].flatMap(Double.init) ?? 300
            try await driver.scroll(direction: direction, distance: distance)
            return .success("Scrolled \(dirStr) by \(distance)")

        // Text actions
        case "type_text":
            guard let text = arguments["text"] else {
                return .error("Missing required argument: text")
            }
            try await driver.typeText(text)
            // Don't echo the typed text — it may contain passwords, PINs, or
            // other secrets that the test injects into the app.
            return .success("Typed \(text.count) character(s)")

        case "clear_text":
            let count = arguments["character_count"].flatMap(Int.init)
            try await driver.clearText(characterCount: count)
            return .success("Text cleared")

        // Navigation
        case "press_back":
            try await driver.pressBack()
            return .success("Pressed back")

        case "press_home":
            try await driver.pressHome()
            return .success("Pressed home")

        case "open_url":
            guard let url = arguments["url"] else {
                return .error("Missing required argument: url")
            }
            try await driver.openURL(url)
            return .success("Opened URL: \(url)")

        case "tap_element":
            let selector = ElementSelector(
                id: arguments["id"],
                label: arguments["label"],
                containsText: arguments["contains_text"]
            )
            guard selector.id != nil || selector.label != nil || selector.containsText != nil else {
                return .error("At least one of id, label, or contains_text is required")
            }
            try await driver.tapElement(selector)
            let desc = selector.label ?? selector.id ?? selector.containsText ?? ""
            return .success("Tapped element: \(desc)")

        // Queries
        case "find_elements":
            let selector = ElementSelector(
                id: arguments["id"],
                label: arguments["label"],
                containsText: arguments["contains_text"],
                description: arguments["description"]
            )
            let elements = try await driver.findElements(
                selector,
                appID: queryScopeAppID(arguments: arguments, driver: driver)
            )
            let descriptions = elements.map {
                "\(colored("[\($0.id)]", .blue)) \(colored($0.label, .yellow))"
            }
            return .success("Found \(elements.count) element(s):\n\(descriptions.joined(separator: "\n"))")

        case "get_view_hierarchy":
            let hierarchy = try await driver.getViewHierarchy(
                appID: queryScopeAppID(arguments: arguments, driver: driver)
            )
            return .success(renderViewNode(hierarchy, indent: 0))

        case "get_screen_context":
            let context = try await driver.getScreenContext()
            return .success(context.summary)

        case "take_screenshot":
            return try await executeTakeScreenshot(driver: driver, arguments: arguments)

        case "is_keyboard_visible":
            let visible = try await driver.isKeyboardVisible()
            return .success(visible ? "true" : "false")

        case "current_app":
            let current = try await driver.currentApp()
            let target = current.targetBundleID.isEmpty ? "(unbound)" : current.targetBundleID
            let frontmost = current.bundleID.isEmpty ? "(unknown)" : current.bundleID
            return .success("frontmost=\(frontmost) target=\(target)")

        case "set_target_app":
            let bundleID = arguments["bundle_id"]
            try await driver.setTargetApp(bundleID: bundleID)
            return .success(
                bundleID?.isEmpty == false
                    ? "Target app set to \(bundleID ?? "")"
                    : "Target app unbound; following the frontmost app"
            )

        // Configuration
        case "set_permission":
            guard let appID = arguments["app_id"],
                  let permission = arguments["permission"]
            else {
                return .error("Missing required arguments: app_id, permission")
            }
            let grantedRaw = arguments["granted"]?.lowercased() ?? "true"
            let granted: Bool
            switch grantedRaw {
            case "true", "1", "yes", "grant": granted = true
            case "false", "0", "no", "revoke": granted = false
            default:
                return .error("Invalid value for granted: '\(grantedRaw)'. Use true or false.")
            }
            try await driver.setPermission(PermissionChange(appID: appID, permission: permission, granted: granted))
            return .success("\(granted ? "Granted" : "Revoked") \(permission) for \(appID)")

        case "set_location":
            guard let lat = arguments["latitude"].flatMap(Double.init),
                  let lon = arguments["longitude"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: latitude, longitude (numbers)")
            }
            try await driver.setLocation(latitude: lat, longitude: lon)
            return .success("Location set to (\(lat), \(lon))")

        case "clear_location":
            try await driver.clearLocation()
            return .success("Location cleared")

        case "set_appearance":
            guard let mode = arguments["appearance"] else {
                return .error("Missing required argument: appearance (light|dark)")
            }
            let appearance: Appearance = mode == "dark" ? .dark : .light
            try await driver.setAppearance(appearance)
            return .success("Appearance set to \(mode)")

        // Audit tools
        case "audit_app":
            return try await executeAudit(driver: driver, arguments: arguments, rulePacks: RulePacks.all)

        case "audit_accessibility":
            return try await executeAudit(
                driver: driver,
                arguments: arguments,
                rulePacks: RulePacks.ux + RulePacks.testability
            )

        case "audit_security":
            return try await executeAudit(driver: driver, arguments: arguments, rulePacks: RulePacks.security)

        // Assistant-facing MCP tools
        case "describe_screen":
            return try await executeDescribeScreen(driver: driver)

        case "suggest_test_actions":
            return try await executeSuggestActions(driver: driver)

        case "analyze_ai_testability":
            return try await executeAnalyzeAITestability(driver: driver)

        case "highlight_a11y_issues":
            return try await executeHighlightA11yIssues(driver: driver)

        case "find_element_by_description":
            guard let description = arguments["description"] else {
                return .error("Missing required argument: description")
            }
            return try await executeFindByDescription(description, driver: driver)

        // Device discovery / app inventory
        case "list_devices":
            return try await executeListDevices(arguments: arguments)

        case "list_apps":
            let apps = try await driver.listApps()
            return formatListApps(apps)

        // Session management
        case "start_session":
            return try await executeStartSession(arguments: arguments)

        case "end_session":
            return try await executeEndSession(arguments: arguments)

        case "list_sessions":
            return await executeListSessions()

        case "get_session_report":
            return try await executeGetSessionReport(arguments: arguments)

        // Intent-level tools
        case "navigate_to":
            guard let description = arguments["description"] else {
                return .error("Missing required argument: description")
            }
            let timeout = arguments["timeout_ms"].flatMap(Int.init) ?? 3000
            return try await executeNavigateTo(description: description, timeoutMS: timeout, driver: driver)

        case "fill_field":
            guard let fieldDescription = arguments["field_description"] else {
                return .error("Missing required argument: field_description")
            }
            guard let value = arguments["value"] else {
                return .error("Missing required argument: value")
            }
            return try await executeFillField(
                fieldDescription: fieldDescription,
                value: value,
                driver: driver
            )

        case "assert_visible":
            guard let description = arguments["description"] else {
                return .error("Missing required argument: description")
            }
            let timeout = arguments["timeout_ms"].flatMap(Int.init) ?? 5000
            return try await executeAssertVisible(
                description: description,
                timeoutMS: timeout,
                driver: driver
            )

        default:
            return .error("Unknown tool: \(toolName)")
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    private func executeAudit(
        driver: any PlatformDriver,
        arguments: [String: String],
        rulePacks: [any AuditRule]
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"] else {
            return .error("Missing required argument: app_id")
        }

        let selectedRules: [any AuditRule] = if let packNames = arguments["rule_packs"] {
            parseRulePacks(packNames)
        } else {
            rulePacks
        }

        // Gather live screen data from the driver
        let context = try await driver.getScreenContext()
        let hierarchy = try await driver.getViewHierarchy()
        let allElements = try await driver.findElements(ElementSelector())
        let interactable = try await driver.getInteractableElements()

        let input = AuditInput(
            appID: appID,
            screenContext: context,
            hierarchy: hierarchy,
            elements: allElements,
            interactableElements: interactable
        )

        let engine = AuditEngine(rules: selectedRules)
        let report = try await engine.run(input)

        return formatAuditReport(report, failOn: arguments["fail_on"])
    }

    private func parseRulePacks(_ names: String) -> [any AuditRule] {
        let packs = names.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var rules: [any AuditRule] = []
        for pack in packs {
            switch pack {
            case "security": rules += RulePacks.security
            case "quality": rules += RulePacks.quality
            case "ux": rules += RulePacks.ux
            case "testability": rules += RulePacks.testability
            case "all": return RulePacks.all
            default: break
            }
        }
        return rules.isEmpty ? RulePacks.all : rules
    }

    private func formatAuditReport(_ report: AuditReport, failOn: String?) -> ToolResult {
        if report.findings.isEmpty {
            return .success("Audit passed: no findings for \(report.appID)")
        }

        var lines = ["Audit report for \(report.appID): \(report.findings.count) finding(s)\n"]

        let sorted = report.findings.sorted { severityOrder($0.severity) < severityOrder($1.severity) }
        for finding in sorted {
            lines.append("[\(finding.severity.rawValue.uppercased())] \(finding.summary)")
            lines
                .append("  Rule: \(finding.ruleID) | Confidence: \(String(format: "%.0f%%", finding.confidence * 100))")
            lines.append("  Fix: \(finding.remediation)")
            lines.append("")
        }

        let isFailure: Bool
        if let threshold = failOn {
            let thresholdOrder = severityOrder(parseSeverity(threshold))
            isFailure = sorted.contains { severityOrder($0.severity) <= thresholdOrder }
        } else {
            isFailure = false
        }

        return ToolResult(content: lines.joined(separator: "\n"), isError: isFailure)
    }

    private func severityOrder(_ severity: Severity) -> Int {
        switch severity {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .info: 4
        }
    }

    private func parseSeverity(_ value: String) -> Severity {
        switch value.lowercased() {
        case "critical": .critical
        case "high": .high
        case "medium": .medium
        case "low": .low
        default: .high
        }
    }

    // MARK: - Assistant Tool Execution

    private func executeDescribeScreen(driver: any PlatformDriver) async throws -> ToolResult {
        let context = try await driver.getScreenContext()
        let hierarchy = try await driver.getViewHierarchy()
        let interactable = try await driver.getInteractableElements()
        let description = formatScreenDescription(
            context: context,
            hierarchy: hierarchy,
            interactableElements: interactable
        )
        let report = ScreenDescriptionReport(
            summary: context.summary,
            screenTitle: context.screenTitle?.isEmpty == false ? context.screenTitle : nil,
            interactableCount: interactable.count
        )
        return try .success(description, structuredContent: Value(report))
    }

    private func executeSuggestActions(driver: any PlatformDriver) async throws -> ToolResult {
        let report = try await buildSuggestionReport(driver: driver)
        return try .success(formatSuggestionReport(report), structuredContent: Value(report))
    }

    private func buildSuggestionReport(driver: any PlatformDriver) async throws -> TestActionSuggestionReport {
        let context = try await driver.getScreenContext()
        let hierarchy = try await driver.getViewHierarchy()
        let screenshot = try await driver.takeScreenshot(format: .png)
        let allElements = try await driver.findElements(ElementSelector())
        let interactable = try await driver.getInteractableElements()
        let filteredElements = filterAppRelevantElements(interactable)
        let diagnostics = collectAccessibilityDiagnostics(
            allElements: allElements,
            interactableElements: filteredElements
        )
        let developerFeedback = developerFeedback(for: diagnostics)
        let request = TestActionSuggestionRequest(
            context: enrichedScreenContext(
                context: context,
                allElements: allElements,
                interactableElements: filteredElements,
                hierarchy: hierarchy
            ),
            hierarchy: hierarchy,
            allElements: filterAppRelevantElements(allElements),
            interactableElements: filteredElements,
            diagnostics: diagnostics,
            developerFeedback: developerFeedback,
            screenshot: screenshot
        )

        return deterministicSuggestionReport(for: request)
    }

    private func executeAnalyzeAITestability(driver: any PlatformDriver) async throws -> ToolResult {
        let context = try await driver.getScreenContext()
        let allElements = try await driver.findElements(ElementSelector())
        let interactable = try await filterAppRelevantElements(driver.getInteractableElements())
        let diagnostics = collectAccessibilityDiagnostics(allElements: allElements, interactableElements: interactable)
        let elementsWithIssues = collectElementA11yIssues(allElements: allElements, interactableElements: interactable)
        let report = AITestabilityReport(
            screenSummary: context.summary,
            interactableCount: interactable.count,
            confidence: testabilityConfidence(diagnostics: diagnostics, interactableCount: interactable.count),
            diagnostics: diagnostics,
            developerFeedback: developerFeedback(for: diagnostics),
            elementsWithIssues: elementsWithIssues
        )

        return try .success(formatAITestabilityReport(report), structuredContent: Value(report))
    }

    private func executeHighlightA11yIssues(driver: any PlatformDriver) async throws -> ToolResult {
        async let hierarchyTask = driver.getViewHierarchy()
        async let allElementsTask = driver.findElements(ElementSelector())
        async let interactableTask = driver.getInteractableElements()
        async let screenshotTask = driver.takeScreenshot(format: .png)

        let hierarchy = try await hierarchyTask
        let allElements = try await allElementsTask
        let interactable = try await filterAppRelevantElements(interactableTask)
        let screenshotData = try await screenshotTask

        let issues = collectElementA11yIssues(allElements: allElements, interactableElements: interactable)

        let viewportWidth = hierarchy.frame?.width ?? 0
        let pngData = Data(screenshotData.bytes)
        let annotated = ScreenshotAnnotator.annotate(
            pngData: pngData,
            issues: issues,
            viewportWidth: viewportWidth
        )

        struct HighlightReport: Codable {
            let issueCount: Int
            let issues: [ElementA11yIssue]
        }
        let report = HighlightReport(issueCount: issues.count, issues: issues)

        let text: String
        if issues.isEmpty {
            text = "No accessibility issues found — nothing to highlight."
        } else {
            let lines = issues.map { issue in
                let typeStr = issue.type.map { " [\($0)]" } ?? ""
                let idStr = issue.id.isEmpty ? "(no id)" : issue.id
                let frameStr = issue.frame
                    .map { f in " at (\(Int(f.x)),\(Int(f.y))) \(Int(f.width))×\(Int(f.height))pt" } ?? ""
                return "  \(idStr)\(typeStr)\(frameStr) — \(issue.issue)"
            }
            text = "\(issues.count) element(s) highlighted (red=missing label, orange=generic, yellow=duplicate):\n"
                + lines.joined(separator: "\n")
        }

        return try ToolResult(
            content: text,
            structuredContent: Value(report),
            image: annotated.map { ToolImageContent(data: $0, mimeType: ImageFormat.png.mimeType) }
        )
    }

    private func executeFindByDescription(
        _ description: String,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let allElements = try await driver.findElements(ElementSelector())
        let lowered = description.lowercased()
        let directMatches = allElements.filter { element in
            element.label.lowercased().contains(lowered) || element.id.lowercased().contains(lowered)
        }
        let matches = directMatches.isEmpty ? try await driver.findByDescription(description) : directMatches
        let report = ElementDescriptionMatchReport(
            query: description,
            matches: matches.map { ElementMatch(id: $0.id, label: $0.label, type: $0.type?.rawValue) }
        )

        if matches.isEmpty {
            return try .success("No elements matched: \(description)", structuredContent: Value(report))
        }
        let descriptions = matches.map { "[\($0.id)] \($0.label)" }
        return try .success(
            "Found \(matches.count) match(es):\n\(descriptions.joined(separator: "\n"))",
            structuredContent: Value(report)
        )
    }

    private func executeTakeScreenshot(
        driver: any PlatformDriver,
        arguments: [String: String]
    ) async throws -> ToolResult {
        let requestedFormat = ImageFormat(parsing: arguments["format"])
        let screenshot = try await driver.takeScreenshot(format: requestedFormat)
        // Trust the format the driver actually produced — some drivers ignore the
        // requested format (e.g. Android always returns PNG), so labeling by the
        // request would hand clients a wrong MIME type.
        let actualFormat = screenshot.format
        let originalData = Data(screenshot.bytes)

        // Downscaling is the single biggest lever on how much a screenshot costs a model to read:
        // a full-resolution phone screen runs into thousands of tokens, and most questions
        // ("which screen am I on", "did the sheet close") are answerable at half scale.
        let scale = arguments["scale"].flatMap(Double.init)
        let data = ScreenshotScaler.scaled(originalData, by: scale, format: actualFormat)
            ?? originalData

        var fields: [String: Value] = [
            "byte_count": .int(data.count),
            "format": .string(actualFormat.rawValue)
        ]
        if data.count != originalData.count {
            fields["original_byte_count"] = .int(originalData.count)
        }

        // The image is in pixels and gestures take points. Reporting both, and the factor between
        // them, is what stops a position read off this image from being passed straight to `tap`
        // — which lands off-screen and still reports success.
        var geometryNote = ""
        if let screen = try? await driver.screenGeometry(), screen.scale > 0 {
            fields["width_pixels"] = .double(screen.widthPixels)
            fields["height_pixels"] = .double(screen.heightPixels)
            fields["width_points"] = .double(screen.widthPoints)
            fields["height_points"] = .double(screen.heightPoints)
            fields["scale"] = .double(screen.scale)
            geometryNote = " — image is \(Int(screen.widthPixels))x\(Int(screen.heightPixels))px;"
                + " gestures take points (\(Int(screen.widthPoints))x\(Int(screen.heightPoints))),"
                + " so divide by \(Int(screen.scale)) or pass unit=pixels"
        }

        var savedNote = ""
        if let output = arguments["output"], !output.isEmpty {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            do {
                try data.write(to: url)
                fields["saved_path"] = .string(url.path)
                savedNote = " — saved to \(url.path)"
            } catch {
                // Keep the declared outputSchema's required fields even on error,
                // for clients that validate structured content strictly.
                return ToolResult(
                    content: "take_screenshot captured \(data.count) bytes but failed to write to \(output): \(error)",
                    isError: true,
                    structuredContent: .object(fields)
                )
            }
        }

        // Surface format downgrades instead of leaving them silent — the request
        // is best-effort (see ScreenCapture.takeScreenshot).
        let formatNote = actualFormat == requestedFormat
            ? ""
            : " — note: requested \(requestedFormat.rawValue) but the driver produced \(actualFormat.rawValue)"

        return ToolResult(
            content: "Screenshot captured: \(data.count) bytes (\(actualFormat.rawValue))"
                + "\(savedNote)\(formatNote)\(geometryNote)",
            structuredContent: .object(fields),
            image: ToolImageContent(data: data, mimeType: actualFormat.mimeType)
        )
    }

    private func parseDirection(_ value: String) -> Direction? {
        switch value.lowercased() {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        default: nil
        }
    }

    private func formatSuggestionReport(_ report: TestActionSuggestionReport) -> String {
        var lines = [
            "Screen intent: \(report.screenIntent)",
            "Confidence: \(report.confidence)",
            "",
            "Suggested actions:"
        ]

        for action in report.suggestedActions.sorted(by: { $0.priority < $1.priority }) {
            lines.append("\(action.priority). \(action.action) - \(action.reason)")
        }

        lines.append("")
        lines.append("Accessibility issues:")
        if report.accessibilityIssues.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.accessibilityIssues.map { "- \($0)" })
        }

        lines.append("")
        lines.append("Developer feedback:")
        if report.developerFeedback.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.developerFeedback.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    private func formatAITestabilityReport(_ report: AITestabilityReport) -> String {
        var lines = [
            "AI testability: \(report.confidence)",
            "Screen summary: \(report.screenSummary)",
            "Interactable elements: \(report.interactableCount)",
            "",
            "Diagnostics:"
        ]

        if report.diagnostics.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.diagnostics.map { "- \($0)" })
        }

        if !report.elementsWithIssues.isEmpty {
            lines.append("")
            lines.append("Elements with accessibility issues (\(report.elementsWithIssues.count)):")
            for issue in report.elementsWithIssues {
                let typeStr = issue.type.map { " [\($0)]" } ?? ""
                let idStr = issue.id.isEmpty ? "(no id)" : issue.id
                let labelStr = issue.label.isEmpty ? "(no label)" : "\"\(issue.label)\""
                let frameStr = issue.frame.map { f in
                    " at (\(Int(f.x)), \(Int(f.y))) \(Int(f.width))×\(Int(f.height))pt"
                } ?? ""
                lines.append("  \(idStr)\(typeStr) \(labelStr)\(frameStr) — \(issue.issue)")
            }
        }

        lines.append("")
        lines.append("Developer feedback:")
        lines.append(contentsOf: report.developerFeedback.map { "- \($0)" })

        return lines.joined(separator: "\n")
    }

    private func filterAppRelevantElements(_ elements: [ElementInfo]) -> [ElementInfo] {
        elements.filter { element in
            guard element.isVisible, element.isEnabled else { return false }
            return !isLikelySystemElement(element)
        }
    }

    private func isLikelySystemElement(_ element: ElementInfo) -> Bool {
        let raw = "\(element.id) \(element.label) \(element.value ?? "")".lowercased()
        let systemTerms = [
            "wifi", "wi-fi", "battery", "signal", "carrier", "clock", "time", "cellular", "status bar",
            "home indicator", "dynamic island", "control center"
        ]

        if systemTerms.contains(where: { raw.contains($0) }) {
            return true
        }

        if element.type == .navigationBar, raw.contains("back") {
            return false
        }

        return raw.hasPrefix("status") || raw.contains("system")
    }

    private func collectAccessibilityDiagnostics(
        allElements: [ElementInfo],
        interactableElements: [ElementInfo]
    ) -> [String] {
        var diagnostics: [String] = []

        let unlabeledInteractables = interactableElements.filter { preferredElementName(
            label: $0.label,
            id: normalizedElementID($0.id)
        ) == nil }
        if !unlabeledInteractables.isEmpty {
            diagnostics
                .append(
                    "\(unlabeledInteractables.count) interactable element(s) are missing a meaningful accessibility label or identifier."
                )
        }

        let genericLabels = interactableElements.filter {
            let label = $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["button", "image", "text field", "text", "label", "item", "view"].contains(label)
        }
        if !genericLabels.isEmpty {
            diagnostics
                .append(
                    "\(genericLabels.count) interactable element(s) use generic labels such as 'Button' or 'Text field'."
                )
        }

        let duplicateLabels = Dictionary(grouping: interactableElements) {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let duplicatedNames = duplicateLabels.filter { key, value in !key.isEmpty && value.count > 1 }
        if !duplicatedNames.isEmpty {
            let names = duplicatedNames.keys.sorted().prefix(3).joined(separator: ", ")
            diagnostics.append("Duplicate interactable labels detected: \(names).")
        }

        let hiddenInteractables = allElements.filter { !$0.isVisible && $0.isEnabled && !isLikelySystemElement($0) }
        if !hiddenInteractables.isEmpty {
            diagnostics
                .append(
                    "\(hiddenInteractables.count) enabled element(s) are hidden, which can confuse screen understanding."
                )
        }

        if interactableElements.isEmpty {
            diagnostics.append("No app-relevant interactable elements were exposed after filtering system UI.")
        }

        return diagnostics
    }

    private func collectElementA11yIssues(
        allElements: [ElementInfo],
        interactableElements: [ElementInfo]
    ) -> [ElementA11yIssue] {
        var issues: [ElementA11yIssue] = []

        let genericLabelSet: Set = ["button", "image", "text field", "text", "label", "item", "view"]

        for element in interactableElements {
            let typeLabel = element.type?.rawValue

            if preferredElementName(label: element.label, id: normalizedElementID(element.id)) == nil {
                issues.append(ElementA11yIssue(
                    id: element.id,
                    label: element.label,
                    type: typeLabel,
                    issue: "missing_label: no meaningful accessibility label or stable identifier",
                    frame: element.frame
                ))
                continue
            }

            let normalizedLabel = element.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if genericLabelSet.contains(normalizedLabel) {
                issues.append(ElementA11yIssue(
                    id: element.id,
                    label: element.label,
                    type: typeLabel,
                    issue: "generic_label: label '\(element.label)' does not describe the element's purpose",
                    frame: element.frame
                ))
            }
        }

        let labelGroups = Dictionary(grouping: interactableElements) {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for (key, group) in labelGroups where !key.isEmpty && group.count > 1 {
            for element in group {
                let alreadyTagged = issues.contains { $0.id == element.id && $0.label == element.label }
                if !alreadyTagged {
                    issues.append(ElementA11yIssue(
                        id: element.id,
                        label: element.label,
                        type: element.type?.rawValue,
                        issue: "duplicate_label: label '\(element.label)' is shared by \(group.count) elements",
                        frame: element.frame
                    ))
                }
            }
        }

        let hiddenEnabled = allElements.filter { !$0.isVisible && $0.isEnabled && !isLikelySystemElement($0) }
        for element in hiddenEnabled {
            issues.append(ElementA11yIssue(
                id: element.id,
                label: element.label,
                type: element.type?.rawValue,
                issue: "hidden_but_enabled: element is enabled but not visible in the accessibility tree",
                frame: element.frame
            ))
        }

        return issues
    }

    private func developerFeedback(for diagnostics: [String]) -> [String] {
        var feedback: [String] = []

        for diagnostic in diagnostics {
            let lowered = diagnostic.lowercased()
            if lowered.contains("missing a meaningful accessibility label") {
                feedback
                    .append(
                        "Add explicit accessibility labels or stable identifiers to every tappable control and input."
                    )
            }
            if lowered.contains("generic labels") {
                feedback
                    .append(
                        "Replace generic labels like 'Button' or 'Text field' with semantic names that reflect the user-visible purpose."
                    )
            }
            if lowered.contains("duplicate interactable labels") {
                feedback
                    .append(
                        "Make repeated controls distinguishable with unique accessibility labels, values, or identifiers."
                    )
            }
            if lowered.contains("enabled element"), lowered.contains("hidden") {
                feedback
                    .append(
                        "Ensure hidden elements are not exposed as enabled accessibility nodes unless they are intentionally interactive."
                    )
            }
            if lowered.contains("no app-relevant interactable elements") {
                feedback
                    .append(
                        "Expose the primary CTA, form fields, and navigation targets through accessibility so AI can identify the main flow."
                    )
            }
        }

        if feedback.isEmpty {
            feedback
                .append(
                    "Keep primary actions, inputs, and navigation controls clearly labeled to preserve high-confidence AI suggestions."
                )
        }

        var seen = Set<String>()
        return feedback.filter { seen.insert($0).inserted }
    }

    private func enrichedScreenContext(
        context: ScreenContext,
        allElements: [ElementInfo],
        interactableElements: [ElementInfo],
        hierarchy: ViewNode
    ) -> ScreenContext {
        let title = context.screenTitle?.isEmpty == false
            ? context.screenTitle
            : inferredScreenTitle(from: allElements, hierarchy: hierarchy)

        let primaryTargets = interactableElements.prefix(3).compactMap { preferredElementName(
            label: $0.label,
            id: normalizedElementID($0.id)
        ) }
        let visibleText = allElements
            .filter { $0.type == .staticText }
            .prefix(4)
            .compactMap { preferredElementName(label: $0.label, id: nil) }

        let summaryParts = [
            title.map { "title=\($0)" },
            !primaryTargets.isEmpty ? "primary_actions=\(primaryTargets.joined(separator: ", "))" : nil,
            !visibleText.isEmpty ? "visible_text=\(visibleText.joined(separator: ", "))" : nil,
            context.summary.isEmpty ? nil : context.summary
        ].compactMap(\.self)

        return ScreenContext(
            summary: summaryParts.joined(separator: " | "),
            interactableCount: interactableElements.count,
            screenTitle: title
        )
    }

    private func inferredScreenTitle(from elements: [ElementInfo], hierarchy: ViewNode) -> String? {
        if let textTitle = elements
            .first(where: { $0.type == .staticText && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.label,
            !textTitle.isEmpty {
            return textTitle
        }

        if !hierarchy.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hierarchy.label
        }

        return nil
    }

    private func normalizedElementID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let genericPatterns = ["button", "text", "label", "image", "view", "cell"]
        if genericPatterns
            .contains(where: { lowered == $0 || lowered.hasPrefix("\($0)") && lowered.count <= $0.count + 2 }) {
            return nil
        }
        return trimmed
    }

    // MARK: - Session tools

    private func executeStartSession(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured. Run `amoo mcp serve` to enable.")
        }
        guard let appID = arguments["app_id"] else {
            return .error("Missing required argument: app_id")
        }
        let platformRaw = arguments["platform"] ?? "ios"
        guard let platform = Platform(rawValue: platformRaw.lowercased()) else {
            return .error("Unknown platform '\(platformRaw)'. Expected 'ios' or 'android'.")
        }
        let deviceHint = arguments["device_hint"]
        let buildPath = arguments["build_path"]
        let launchArgs: [String] = arguments["launch_args"]
            .map { $0.split(separator: ",").map(String.init) } ?? []
        let environment = Self.parseEnvironment(arguments["environment"])

        do {
            let session = try await manager.startSession(
                appID: appID,
                platform: platform,
                deviceHint: deviceHint,
                buildPath: buildPath,
                arguments: launchArgs,
                environment: environment
            )
            let summary: [String: Value] = [
                "session_id": .string(session.id),
                "app_id": .string(session.appID),
                "device_id": .string(session.deviceID),
                "platform": .string(session.platform.rawValue)
            ]
            let text = "Started session \(session.id) for \(session.appID) on \(session.platform.rawValue) device \(session.deviceID)."
            return .success(text, structuredContent: .object(summary))
        } catch {
            return .error("start_session failed: \(error)")
        }
    }

    private func executeEndSession(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        guard let sessionID = arguments["session_id"] else {
            return .error("Missing required argument: session_id")
        }

        // Capture action count before close.
        let actionCount: Int
        if let session = await manager.session(sessionID) {
            actionCount = await session.actions.count
        } else {
            return .error("Session not found: \(sessionID)")
        }

        do {
            try await manager.endSession(sessionID)
        } catch {
            return .error("end_session failed: \(error)")
        }

        let summary: [String: Value] = [
            "session_id": .string(sessionID),
            "ended_at": .string(ISO8601DateFormatter().string(from: Date())),
            "action_count": .int(actionCount)
        ]
        return .success(
            "Ended session \(sessionID) (\(actionCount) action(s) recorded).",
            structuredContent: .object(summary)
        )
    }

    private func executeListSessions() async -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        let sessions = await manager.allSessions()
        var rows: [Value] = []
        var lines: [String] = []
        for session in sessions {
            let count = await session.actions.count
            let isActive = await session.isActive
            rows.append(.object([
                "session_id": .string(session.id),
                "app_id": .string(session.appID),
                "device_id": .string(session.deviceID),
                "platform": .string(session.platform.rawValue),
                "started_at": .string(ISO8601DateFormatter().string(from: session.startedAt)),
                "action_count": .int(count),
                "is_active": .bool(isActive)
            ]))
            lines.append(
                "[\(session.id)] \(session.appID) on \(session.platform.rawValue) — \(count) action(s)"
                    + (isActive ? "" : " (closed)")
            )
        }
        let summary = lines.isEmpty ? "No active sessions." : lines.joined(separator: "\n")
        return .success(summary, structuredContent: .object(["sessions": .array(rows)]))
    }

    private func executeGetSessionReport(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        guard let sessionID = arguments["session_id"] else {
            return .error("Missing required argument: session_id")
        }
        guard let session = await manager.session(sessionID) else {
            return .error("Session not found: \(sessionID)")
        }
        let report = await SessionReport.make(from: session)
        let summary = "Session \(report.sessionID) — \(report.actionCount) action(s), \(report.errorCount) error(s)."
        return try .success(summary, structuredContent: Value(report))
    }

    // MARK: - Device discovery / app inventory

    private func executeListDevices(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured. Device discovery requires it.")
        }
        let platformFilter: Platform?
        if let raw = arguments["platform"] {
            guard let parsed = Platform(rawValue: raw.lowercased()) else {
                return .error("Unknown platform '\(raw)'. Expected 'ios' or 'android'.")
            }
            platformFilter = parsed
        } else {
            platformFilter = nil
        }

        let devices = try await manager.listAvailableDevices(platform: platformFilter)
        var rows: [Value] = []
        var lines: [String] = []
        for device in devices {
            rows.append(.object([
                "id": .string(device.id),
                "name": .string(device.name),
                "platform": .string(device.platform.rawValue),
                "os_version": .string(device.osVersion),
                "state": .string(device.state.rawValue)
            ]))
            lines.append("[\(device.platform.rawValue)] \(device.name) (\(device.id)) — \(device.state.rawValue)")
        }
        let text = lines.isEmpty ? "No devices found." : lines.joined(separator: "\n")
        return .success(text, structuredContent: .object(["devices": .array(rows)]))
    }

    private func formatListApps(_ apps: [AppInfo]) -> ToolResult {
        var rows: [Value] = []
        var lines: [String] = []
        for app in apps {
            var fields: [String: Value] = ["app_id": .string(app.appID)]
            if let name = app.name {
                fields["name"] = .string(name)
            }
            if let version = app.version {
                fields["version"] = .string(version)
            }
            rows.append(.object(fields))
            let suffix = [app.name, app.version].compactMap(\.self).joined(separator: " ")
            lines.append(suffix.isEmpty ? app.appID : "\(app.appID) — \(suffix)")
        }
        let text = lines.isEmpty ? "No installed apps reported." : lines.joined(separator: "\n")
        return .success(text, structuredContent: .object(["apps": .array(rows)]))
    }

    // MARK: - Intent tools

    private func executeNavigateTo(
        description: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let lowered = description.lowercased()

        // (a) If the current screen already matches, succeed immediately.
        let initial = try await driver.getScreenContext()
        if screenContextMatches(initial, query: lowered) {
            return .success(
                "Already on target screen.\n\(initial.summary)",
                structuredContent: .object([
                    "navigated": .bool(false),
                    "matched_current_screen": .bool(true),
                    "screen_summary": .string(initial.summary)
                ])
            )
        }

        // (b) Search elements; tap the first interactable match.
        let candidate = try await findFirstNavigableElement(query: description, driver: driver)
        guard let target = candidate else {
            return ToolResult(
                content: """
                navigate_to failed: no element matches '\(description)'.
                Current screen: \(initial.summary)
                """,
                isError: true,
                structuredContent: .object([
                    "navigated": .bool(false),
                    "reason": .string("no_match"),
                    "screen_summary": .string(initial.summary)
                ])
            )
        }

        let selector = ElementSelector(
            id: target.id.isEmpty ? nil : target.id,
            label: target.label.isEmpty ? nil : target.label
        )
        try await driver.tapElement(selector)
        try? await Task.sleep(for: .milliseconds(800))

        // Wait for screen change up to the requested timeout.
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        var current = initial
        while Date() < deadline {
            current = await (try? driver.getScreenContext()) ?? current
            if current.summary != initial.summary {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        return .success(
            "Tapped '\(preferredElementName(label: target.label, id: target.id) ?? target.id)'.\n\(current.summary)",
            structuredContent: .object([
                "navigated": .bool(true),
                "element_id": .string(target.id),
                "element_label": .string(target.label),
                "screen_summary": .string(current.summary)
            ])
        )
    }

    private func executeFillField(
        fieldDescription: String,
        value: String,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let selector = ElementSelector(description: fieldDescription)
        try await driver.setText(selector, text: value)
        return .success(
            "Filled '\(fieldDescription)' with \(value.count) char(s).",
            structuredContent: .object([
                "field_description": .string(fieldDescription),
                "value_length": .int(value.count)
            ])
        )
    }

    private func executeAssertVisible(
        description: String,
        timeoutMS: Int,
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)
        let lowered = description.lowercased()
        var lastScreenSummary = ""
        repeat {
            if let context = try? await driver.getScreenContext() {
                lastScreenSummary = context.summary
            }
            if let match = try await findFirstNavigableElement(query: description, driver: driver) {
                return .success(
                    "Visible: '\(preferredElementName(label: match.label, id: match.id) ?? match.id)'",
                    structuredContent: .object([
                        "passed": .bool(true),
                        "element_id": .string(match.id),
                        "element_label": .string(match.label),
                        "element_type": .string(match.type?.rawValue ?? ""),
                        "screen_summary": .string(lastScreenSummary)
                    ])
                )
            }
            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        return ToolResult(
            content: """
            assert_visible failed: no element matched '\(description)' within \(timeoutMS)ms.
            Current screen: \(lastScreenSummary)
            """,
            isError: true,
            structuredContent: .object([
                "passed": .bool(false),
                "query": .string(description),
                "query_lowercased": .string(lowered),
                "screen_summary": .string(lastScreenSummary)
            ])
        )
    }

    // MARK: - Intent tool helpers

    private func findFirstNavigableElement(
        query: String,
        driver: any PlatformDriver
    ) async throws -> ElementInfo? {
        let lowered = query.lowercased()
        let allElements = try await driver.findElements(ElementSelector())
        let filtered = filterAppRelevantElements(allElements)
        if let match = filtered.first(where: {
            $0.label.lowercased().contains(lowered) || $0.id.lowercased().contains(lowered)
        }) {
            return match
        }
        let semantic = await (try? driver.findByDescription(query)) ?? []
        return semantic.first
    }

    private func screenContextMatches(_ context: ScreenContext, query lowered: String) -> Bool {
        if context.summary.lowercased().contains(lowered) {
            return true
        }
        if let title = context.screenTitle, title.lowercased().contains(lowered) {
            return true
        }
        return false
    }
}

// MARK: - View hierarchy rendering

private func renderViewNode(_ node: ViewNode, indent: Int) -> String {
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
