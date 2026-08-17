import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    // swiftlint:disable cyclomatic_complexity function_body_length
    func dispatch(toolName: String, arguments: [String: String]) async throws -> ToolResult {
        let driver = await resolveDriver(arguments: arguments)
        switch toolName {
        // Device lifecycle
        case "device_boot":
            try await driver.boot()
            let info = try await driver.deviceInfo()
            guard info.state == .booted else {
                throw AmooError.commandFailed(command: "device_boot", output: "device state is \(info.state.rawValue)")
            }
            return .success(
                "Device booted and verified: \(info.name)",
                structuredContent: .object(["verified": .bool(true), "device_id": .string(info.id)])
            )

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
            return await verifyLaunch(
                appID: appID,
                driver: driver,
                timeoutMS: arguments["timeout_ms"].flatMap(Int.init) ?? 5000
            )

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

        case "set_text":
            guard let value = arguments["value"] else {
                return .error("Missing required argument: value")
            }
            guard let selector = preferredSelector(arguments: arguments) else {
                return .error("At least one of id, label, or contains_text is required")
            }
            return try await executeSetText(
                selector: selector,
                value: value,
                driver: driver,
                appID: queryScopeAppID(arguments: arguments, driver: driver)
            )

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
            guard let selector = preferredSelector(arguments: arguments) else {
                return .error("At least one of id, label, or contains_text is required")
            }
            let appID = queryScopeAppID(arguments: arguments, driver: driver)
            guard let matched = try await driver.findElements(selector, appID: appID).first else {
                return .error("tap_element failed: no element matched the selector")
            }
            guard matched.isVisible, matched.isEnabled else {
                return .error("tap_element failed: matched element is not visible and enabled")
            }
            try await driver.tapElement(
                selector,
                appID: appID
            )
            return .success(
                "Tapped verified element [\(matched.id)] \(matched.label)",
                structuredContent: .object([
                    "verified": .bool(true),
                    "element_id": .string(matched.id),
                    "element_label": .string(matched.label)
                ])
            )

        // Queries
        case "find_elements":
            let selector = ElementSelector(
                id: arguments["id"],
                label: arguments["label"],
                containsText: arguments["contains_text"],
                description: arguments["description"],
                labeledOnly: boolArgument(arguments["labeled_only"]) ?? false
            )
            let elements = try await driver.findElements(
                selector,
                appID: queryScopeAppID(arguments: arguments, driver: driver)
            )
            // Frames are included so a match is directly tappable: without them the only way to
            // act on a found element was a screenshot round trip to read its position off the
            // image — in pixels, needing conversion. These are points, ready for `tap`.
            //
            // An element with neither id nor label would otherwise render as two empty brackets.
            // It is listed as its type, because for an unlabeled control the frame *is* the whole
            // answer — `tap` at that centre is the only way to reach it.
            let descriptions = elements.map { element in
                let position = element.frame.map {
                    " at (\(Int($0.centre.x)),\(Int($0.centre.y))) pts \(Int($0.width))x\(Int($0.height))"
                } ?? ""
                guard !element.id.isEmpty || !element.label.isEmpty else {
                    let type = element.type?.rawValue ?? "element"
                    return "\(colored("[unlabeled]", .blue)) \(colored(type, .yellow))\(position)"
                }
                return "\(colored("[\(element.id)]", .blue)) \(colored(element.label, .yellow))\(position)"
            }
            return .success("Found \(elements.count) element(s):\n\(descriptions.joined(separator: "\n"))")

        case "get_view_hierarchy":
            let hierarchy = try await driver.getViewHierarchy(
                appID: queryScopeAppID(arguments: arguments, driver: driver)
            )
            return .success(renderViewNode(hierarchy, indent: 0))

        case "get_screen_context":
            let context = try await driver.getScreenContext()
            return .success(
                context.summary,
                structuredContent: .object([
                    "screen_summary": .string(context.summary),
                    "screen_token": .string(screenToken(context.summary))
                ])
            )

        case "take_screenshot":
            return try await executeTakeScreenshot(driver: driver, arguments: arguments)

        case "is_keyboard_visible":
            let visible = try await driver.isKeyboardVisible()
            return .success(visible ? "true" : "false")

        case "current_app":
            let current = try await driver.currentApp()
            let target = current.targetBundleID.isEmpty ? "(unbound)" : current.targetBundleID
            let frontmost = current.bundleID.isEmpty ? "(unknown)" : current.bundleID
            return .success(
                "frontmost=\(frontmost) target=\(target)",
                structuredContent: .object([
                    "bundle_id": .string(current.bundleID),
                    "target_bundle_id": .string(current.targetBundleID)
                ])
            )

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
            guard let value = arguments["value"] else {
                return .error("Missing required argument: value")
            }
            guard let selector = preferredSelector(arguments: arguments, includeDescription: true) else {
                return .error("At least one of id, label, contains_text, or field_description is required")
            }
            return try await executeSetText(
                selector: selector,
                value: value,
                driver: driver,
                appID: queryScopeAppID(arguments: arguments, driver: driver)
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

        case "assert_enabled":
            guard let selector = preferredSelector(arguments: arguments, includeDescription: true) else {
                return .error("An element selector is required")
            }
            return try await executeElementAssertion(
                kind: .enabled,
                selector: selector,
                arguments: arguments,
                driver: driver
            )

        case "assert_absent":
            guard let selector = preferredSelector(arguments: arguments, includeDescription: true) else {
                return .error("An element selector is required")
            }
            return try await executeElementAssertion(
                kind: .absent,
                selector: selector,
                arguments: arguments,
                driver: driver
            )

        case "assert_value":
            guard let selector = preferredSelector(arguments: arguments, includeDescription: true) else {
                return .error("An element selector is required")
            }
            guard arguments["expected"] != nil || arguments["contains"] != nil else {
                return .error("One of expected or contains is required")
            }
            return try await executeElementAssertion(
                kind: .value,
                selector: selector,
                arguments: arguments,
                driver: driver
            )

        case "assert_screen_changed":
            guard let baseline = arguments["from_token"] else {
                return .error("Missing required argument: from_token")
            }
            return await executeAssertScreenChanged(
                baseline: baseline,
                timeoutMS: arguments["timeout_ms"].flatMap(Int.init) ?? 3000,
                driver: driver
            )

        default:
            return .error("Unknown tool: \(toolName)")
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length
}

/// Reads a boolean tool argument. Every argument arrives as a string, and MCP clients spell a flag
/// as any of these, so accepting one spelling would reject calls that plainly meant true.
func boolArgument(_ raw: String?) -> Bool? {
    switch raw?.lowercased() {
    case "true", "1", "yes": true
    case "false", "0", "no": false
    default: nil
    }
}
