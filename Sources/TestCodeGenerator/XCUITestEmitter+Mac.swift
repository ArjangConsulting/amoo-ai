import StudioProtocol

/// The macOS variant of the XCUITest emitter.
///
/// A Mac has a pointer and a scroll wheel rather than touch, so a tap is a click, a swipe or scroll is
/// a wheel scroll of the window (a drag would select text), and there is no pinch or back gesture.
/// The scroll deltas mirror the macOS companion (`XCUITestBridge.macScroll`): the content follows
/// the gesture direction, so a recorded `scroll(down)` — a swipe up — becomes a negative `deltaY`.
extension XCUITestEmitter {
    /// The OS the generated XCUITest runs on. Both use `XCUIApplication`, but the input vocabulary
    /// differs: a Mac has a pointer and a scroll wheel, no touch, no swipe, no pinch and no back.
    public enum Target: Sendable, Equatable {
        case ios
        case macos
    }

    /// Wheel travel in points when the recording named no `distance`; the live tools default to 300.
    private static let defaultScrollDistance = 300.0

    /// The window a scroll is aimed at. A Mac app's own frame is infinite, so the app element has no
    /// point to scroll at.
    private static let scrollWindow = "app.windows.firstMatch"

    /// Refuses a test whose context asks for something a Mac cannot do.
    static func checkTarget(_ target: Target, supports test: StudioAuthoredTest) throws {
        guard target == .macos, test.testContext?.requiredIdiom != nil else { return }
        throw TestCodeGeneratorError.unsupportedOnTarget(
            tool: "requiredIdiom",
            target: "macOS",
            reason: "a Mac has no iPhone or iPad idiom to require."
        )
    }

    /// `replaceText` and, on iOS, `pressBack`, at member indentation and without a trailing newline.
    static func inputHelpers(for target: Target) -> String {
        switch target {
        case .ios:
            """
                private func replaceText(in element: XCUIElement, with text: String) {
                    element.tap()
                    if let currentValue = element.value as? String, !currentValue.isEmpty {
                        element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
                    }
                    if !text.isEmpty {
                        element.typeText(text)
                    }
                }

                private func pressBack() {
                    let backButton = app.navigationBars.buttons.element(boundBy: 0)
                    if backButton.exists, backButton.isHittable {
                        backButton.tap()
                    } else {
                        app.swipeRight()
                    }
                }
            """
        case .macos:
            """
                private func replaceText(in element: XCUIElement, with text: String) {
                    element.click()
                    element.typeKey("a", modifierFlags: .command)
                    element.typeKey(.delete, modifierFlags: [])
                    if !text.isEmpty {
                        element.typeText(text)
                    }
                }
            """
        }
    }

    /// The macOS statement for a tool whose iOS rendering is touch-only, or nil when the iOS
    /// rendering already works on a Mac (waits, assertions, `type_text`, screenshots, relaunch).
    static func macStatement(
        for operation: StudioToolOperation,
        tool: StudioTool,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String? {
        switch tool {
        case .tapElement:
            let (_, variable, declaration) = try lookup(
                operation, context: context, localNames: &localNames, lookups: &lookups
            )
            return try """
            \(declaration)
            \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
            \(indent)\(variable).click()
            """

        case .swipeInDirection, .scroll, .scrollToElement:
            return try macScrollStatement(
                for: operation, tool: tool, context: context, localNames: &localNames, lookups: &lookups
            )

        case .drag:
            let timing = try DragArguments(operation)
            let (_, source, sourceDeclaration) = try lookup(
                operation, context: context, localNames: &localNames, lookups: &lookups
            )
            let (_, target, targetDeclaration) = try lookup(
                operation.dropTarget, context: context, localNames: &localNames, lookups: &lookups
            )
            return try """
            \(sourceDeclaration)
            \(targetDeclaration)
            \(indent)\(waitCall("waitForHittability", source, operation, context: context))
            \(indent)\(waitCall("waitForExistence", target, operation, context: context))
            \(indent)\(source).click(forDuration: \(timing.holdSeconds), thenDragTo: \(target))
            """

        case .pinch:
            throw TestCodeGeneratorError.unsupportedOnTarget(
                tool: operation.tool, target: "macOS", reason: "a Mac has no pinch gesture."
            )

        case .pressBack:
            throw TestCodeGeneratorError.unsupportedOnTarget(
                tool: operation.tool, target: "macOS", reason: "a Mac has no system back action."
            )

        default:
            return nil
        }
    }

    /// `swipe_in_direction`, `scroll` and `scroll_to_element` as wheel scrolls.
    private static func macScrollStatement(
        for operation: StudioToolOperation,
        tool: StudioTool,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        switch tool {
        case .swipeInDirection:
            let direction = try GestureDirection.gestureDirection(
                for: operation.tool, rawDirection: operation.arguments["direction"] ?? missingDirection(operation)
            )
            let scroll = try scrollCall(direction, operation: operation)
            guard operation.arguments["element_id"] != nil || operation.arguments["element_label"] != nil else {
                return "\(indent)\(scrollWindow).\(scroll)"
            }
            let (_, variable, declaration) = try lookup(
                operation,
                context: context,
                localNames: &localNames,
                lookups: &lookups,
                idKey: "element_id",
                labelKey: "element_label"
            )
            return try """
            \(declaration)
            \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
            \(indent)\(variable).\(scroll)
            """

        case .scroll:
            let direction = try GestureDirection.gestureDirection(
                for: operation.tool, rawDirection: operation.arguments["direction"] ?? missingDirection(operation)
            )
            return try "\(indent)\(scrollWindow).\(scrollCall(direction, operation: operation))"

        case .scrollToElement:
            let (_, variable, declaration) = try lookup(
                operation, context: context, localNames: &localNames, lookups: &lookups
            )
            let direction = try GestureDirection.gestureDirection(
                for: "scroll", rawDirection: operation.arguments["direction"] ?? "down"
            )
            let attempts = operation.arguments["max_attempts"].flatMap(Int.init) ?? 8
            let scroll = try scrollCall(direction, operation: operation)
            return try """
            \(declaration)
            \(indent)for _ in 0 ..< \(attempts) where !\(variable).isHittable { \(scrollWindow).\(scroll) }
            \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
            """

        default:
            throw TestCodeGeneratorError.unsupportedTool(operation.tool)
        }
    }

    private static func missingDirection(_ operation: StudioToolOperation) throws -> String {
        throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "direction")
    }

    /// `scroll(byDeltaX:deltaY:)` moving the content the way a finger swiping in `direction` would.
    private static func scrollCall(_ direction: GestureDirection, operation: StudioToolOperation) throws -> String {
        var distance = defaultScrollDistance
        if let raw = operation.arguments["distance"] {
            guard let parsed = Double(raw), parsed > 0, parsed.isFinite else {
                throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: "distance", value: raw)
            }
            distance = parsed
        }
        let points = distance.rounded() == distance ? String(Int(distance)) : String(distance)
        let (dx, dy): (String, String) = switch direction {
        case .up: ("0", "-\(points)")
        case .down: ("0", points)
        case .left: ("-\(points)", "0")
        case .right: (points, "0")
        }
        return "scroll(byDeltaX: \(dx), deltaY: \(dy))"
    }
}
