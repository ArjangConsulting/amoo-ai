import AuditEngine
import Foundation
import MobileTestingCore

public protocol ToolExecutor: Sendable {
    func execute(toolName: String, arguments: [String: String]) async -> ToolResult
}

// swiftlint:disable:next type_body_length
public actor DriverToolExecutor: ToolExecutor {
    private let driver: any PlatformDriver
    private let aiProvider: (any AIProvider)?

    public init(driver: any PlatformDriver, aiProvider: (any AIProvider)? = nil) {
        self.driver = driver
        self.aiProvider = aiProvider
    }

    public func execute(toolName: String, arguments: [String: String]) async -> ToolResult {
        do {
            return try await dispatch(toolName: toolName, arguments: arguments)
        } catch {
            return .error("\(toolName) failed: \(error)")
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func dispatch(toolName: String, arguments: [String: String]) async throws -> ToolResult {
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
            try await driver.launchApp(appID: appID, arguments: [], environment: [:])
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
            try await driver.tap(at: Point(x: x, y: y))
            return .success("Tapped at (\(x), \(y))")

        case "double_tap":
            guard let x = arguments["x"].flatMap(Double.init),
                  let y = arguments["y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: x, y (numbers)")
            }
            try await driver.doubleTap(at: Point(x: x, y: y))
            return .success("Double tapped at (\(x), \(y))")

        case "long_press":
            guard let x = arguments["x"].flatMap(Double.init),
                  let y = arguments["y"].flatMap(Double.init)
            else {
                return .error("Missing required arguments: x, y (numbers)")
            }
            let ms = arguments["duration_ms"].flatMap(Int.init) ?? 500
            try await driver.longPress(at: Point(x: x, y: y), duration: Duration(milliseconds: ms))
            return .success("Long pressed at (\(x), \(y)) for \(ms)ms")

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
            try await driver.swipe(
                from: Point(x: fromX, y: fromY),
                to: Point(x: toX, y: toY),
                duration: Duration(milliseconds: ms)
            )
            return .success("Swiped from (\(fromX),\(fromY)) to (\(toX),\(toY))")

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
            let elements = try await driver.findElements(selector)
            let descriptions = elements.map {
                "\(colored("[\($0.id)]", .blue)) \(colored($0.label, .yellow))"
            }
            return .success("Found \(elements.count) element(s):\n\(descriptions.joined(separator: "\n"))")

        case "get_view_hierarchy":
            let hierarchy = try await driver.getViewHierarchy()
            return .success(renderViewNode(hierarchy, indent: 0))

        case "get_screen_context":
            let context = try await driver.getScreenContext()
            return .success(context.summary)

        case "take_screenshot":
            let formatStr = arguments["format"] ?? "png"
            let format: ImageFormat = formatStr == "jpeg" ? .jpeg : .png
            let screenshot = try await driver.takeScreenshot(format: format)
            return .success("Screenshot captured: \(screenshot.bytes.count) bytes (\(formatStr))")

        case "is_keyboard_visible":
            let visible = try await driver.isKeyboardVisible()
            return .success(visible ? "true" : "false")

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
            return try await executeAudit(arguments: arguments, rulePacks: RulePacks.all)

        case "audit_accessibility":
            return try await executeAudit(arguments: arguments, rulePacks: RulePacks.ux + RulePacks.testability)

        case "audit_security":
            return try await executeAudit(arguments: arguments, rulePacks: RulePacks.security)

        // AI tools
        case "ai_describe_screen":
            return try await executeDescribeScreen()

        case "ai_suggest_actions":
            return try await executeSuggestActions()

        case "ai_suggest_actions_json":
            return try await executeSuggestActionsJSON()

        case "ai_find_by_description":
            guard let description = arguments["description"] else {
                return .error("Missing required argument: description")
            }
            return try await executeFindByDescription(description)

        default:
            return .error("Unknown tool: \(toolName)")
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    private func executeAudit(arguments: [String: String], rulePacks: [any AuditRule]) async throws -> ToolResult {
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

    // MARK: - AI Tool Execution

    private func executeDescribeScreen() async throws -> ToolResult {
        let context = try await driver.getScreenContext()
        let hierarchy = try await driver.getViewHierarchy()
        let interactable = try await driver.getInteractableElements()
        let fallbackDescription = formatScreenDescription(
            context: context,
            hierarchy: hierarchy,
            interactableElements: interactable
        )
        let localDescription = formatScreenDescription(
            context: context,
            hierarchy: hierarchy,
            interactableElements: []
        )

        if let ai = aiProvider {
            let description = try await ai.describeScreen(context: context, hierarchy: hierarchy)
            let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalizedDescription == context.summary || normalizedDescription == localDescription {
                return .success(fallbackDescription)
            }

            return .success(description)
        }
        return .success(fallbackDescription)
    }

    private func executeSuggestActions() async throws -> ToolResult {
        let report = try await buildSuggestionReport()
        return .success(formatSuggestionReport(report))
    }

    private func executeSuggestActionsJSON() async throws -> ToolResult {
        let report = try await buildSuggestionReport()
        return .success(try encodeSuggestionReport(report))
    }

    private func buildSuggestionReport() async throws -> AISuggestionReport {
        let context = try await driver.getScreenContext()
        let hierarchy = try await driver.getViewHierarchy()
        let screenshot = try await driver.takeScreenshot(format: .png)
        let allElements = try await driver.findElements(ElementSelector())
        let interactable = try await driver.getInteractableElements()
        let filteredElements = filterAppRelevantElements(interactable)
        let diagnostics = collectAccessibilityDiagnostics(allElements: allElements, interactableElements: filteredElements)
        let developerFeedback = developerFeedback(for: diagnostics)
        let request = AISuggestionRequest(
            context: enrichedScreenContext(context: context, allElements: allElements, interactableElements: filteredElements, hierarchy: hierarchy),
            hierarchy: hierarchy,
            allElements: filterAppRelevantElements(allElements),
            interactableElements: filteredElements,
            diagnostics: diagnostics,
            developerFeedback: developerFeedback,
            screenshot: screenshot
        )

        if let ai = aiProvider {
            return try await ai.suggestActions(request: request)
        }

        return deterministicSuggestionReport(for: request)
    }

    private func executeFindByDescription(_ description: String) async throws -> ToolResult {
        if let ai = aiProvider {
            let allElements = try await driver.findElements(ElementSelector())
            let matches = try await ai.resolveDescription(description, elements: allElements)
            if matches.isEmpty {
                return .success("No elements matched: \(description)")
            }
            let descriptions = matches.map { "[\($0.id)] \($0.label)" }
            return .success("Found \(matches.count) match(es):\n\(descriptions.joined(separator: "\n"))")
        }

        // Fallback: use driver's built-in description search
        let matches = try await driver.findByDescription(description)
        if matches.isEmpty {
            return .success("No elements matched: \(description)")
        }
        let descriptions = matches.map { "[\($0.id)] \($0.label)" }
        return .success("Found \(matches.count) match(es):\n\(descriptions.joined(separator: "\n"))")
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

    private func formatSuggestionReport(_ report: AISuggestionReport) -> String {
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

    private func encodeSuggestionReport(_ report: AISuggestionReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MCPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode suggestion report"])
        }
        return json
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

    private func collectAccessibilityDiagnostics(allElements: [ElementInfo], interactableElements: [ElementInfo]) -> [String] {
        var diagnostics: [String] = []

        let unlabeledInteractables = interactableElements.filter { preferredElementName(label: $0.label, id: normalizedElementID($0.id)) == nil }
        if !unlabeledInteractables.isEmpty {
            diagnostics.append("\(unlabeledInteractables.count) interactable element(s) are missing a meaningful accessibility label or identifier.")
        }

        let genericLabels = interactableElements.filter {
            let label = $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["button", "image", "text field", "text", "label", "item", "view"].contains(label)
        }
        if !genericLabels.isEmpty {
            diagnostics.append("\(genericLabels.count) interactable element(s) use generic labels such as 'Button' or 'Text field'.")
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
            diagnostics.append("\(hiddenInteractables.count) enabled element(s) are hidden, which can confuse screen understanding.")
        }

        if interactableElements.isEmpty {
            diagnostics.append("No app-relevant interactable elements were exposed after filtering system UI.")
        }

        return diagnostics
    }

    private func developerFeedback(for diagnostics: [String]) -> [String] {
        var feedback: [String] = []

        for diagnostic in diagnostics {
            let lowered = diagnostic.lowercased()
            if lowered.contains("missing a meaningful accessibility label") {
                feedback.append("Add explicit accessibility labels or stable identifiers to every tappable control and input.")
            }
            if lowered.contains("generic labels") {
                feedback.append("Replace generic labels like 'Button' or 'Text field' with semantic names that reflect the user-visible purpose.")
            }
            if lowered.contains("duplicate interactable labels") {
                feedback.append("Make repeated controls distinguishable with unique accessibility labels, values, or identifiers.")
            }
            if lowered.contains("enabled element") && lowered.contains("hidden") {
                feedback.append("Ensure hidden elements are not exposed as enabled accessibility nodes unless they are intentionally interactive.")
            }
            if lowered.contains("no app-relevant interactable elements") {
                feedback.append("Expose the primary CTA, form fields, and navigation targets through accessibility so AI can identify the main flow.")
            }
        }

        if feedback.isEmpty {
            feedback.append("Keep primary actions, inputs, and navigation controls clearly labeled to preserve high-confidence AI suggestions.")
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

        let primaryTargets = interactableElements.prefix(3).compactMap { preferredElementName(label: $0.label, id: normalizedElementID($0.id)) }
        let visibleText = allElements
            .filter { $0.type == .staticText }
            .prefix(4)
            .compactMap { preferredElementName(label: $0.label, id: nil) }

        let summaryParts = [
            title.map { "title=\($0)" },
            !primaryTargets.isEmpty ? "primary_actions=\(primaryTargets.joined(separator: ", "))" : nil,
            !visibleText.isEmpty ? "visible_text=\(visibleText.joined(separator: ", "))" : nil,
            context.summary.isEmpty ? nil : context.summary
        ].compactMap { $0 }

        return ScreenContext(
            summary: summaryParts.joined(separator: " | "),
            interactableCount: interactableElements.count,
            screenTitle: title
        )
    }

    private func inferredScreenTitle(from elements: [ElementInfo], hierarchy: ViewNode) -> String? {
        if let textTitle = elements.first(where: { $0.type == .staticText && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.label,
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
        if genericPatterns.contains(where: { lowered == $0 || lowered.hasPrefix("\($0)") && lowered.count <= $0.count + 2 }) {
            return nil
        }
        return trimmed
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
        if !node.isEnabled { return " \(colored("(disabled)", .red))" }
        if !node.isVisible { return " \(colored("(hidden)", .gray))" }
        return ""
    }()

    parts.append("\(prefix)\(typeStr)\(labelStr)\(valueStr)\(idStr)\(stateStr)")

    for child in node.children {
        parts.append(renderViewNode(child, indent: indent + 1))
    }

    return parts.joined(separator: "\n")
}
