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

        if let ai = aiProvider {
            let description = try await ai.describeScreen(context: context, hierarchy: hierarchy)
            return .success(description)
        }
        return .success(context.summary)
    }

    private func executeSuggestActions() async throws -> ToolResult {
        let context = try await driver.getScreenContext()
        let interactable = try await driver.getInteractableElements()

        if let ai = aiProvider {
            let suggestions = try await ai.suggestActions(context: context, interactableElements: interactable)
            return .success(suggestions.joined(separator: "\n"))
        }

        // Fallback: deterministic suggestions based on interactable elements
        let suggestions = interactable.prefix(5).map { el in
            "Tap \(el.label.isEmpty ? el.id : el.label)"
        }
        return .success(suggestions.isEmpty ? "No interactable elements found" : suggestions.joined(separator: "\n"))
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
