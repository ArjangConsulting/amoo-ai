import StudioProtocol

extension XCUITestEmitter {
    /// Swipes until the element is hittable (up to `max_attempts`, default 8), then waits on it so a
    /// target that never appears fails the test where it was expected.
    ///
    /// `scroll_to_element` names where to scroll, like `scroll`, so the finger moves the other way.
    static func scrollToElementStatement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        let (_, variable, declaration) = try lookup(
            operation, context: context, localNames: &localNames, lookups: &lookups
        )
        let direction = try GestureDirection.gestureDirection(
            for: "scroll", rawDirection: operation.arguments["direction"] ?? "down"
        )
        let attempts = operation.arguments["max_attempts"].flatMap(Int.init) ?? 8
        return try """
        \(declaration)
        \(indent)for _ in 0 ..< \(attempts) where !\(variable).isHittable { app.\(gestureMethod(direction))() }
        \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
        """
    }

    static func gestureMethod(_ direction: GestureDirection) -> String {
        switch direction {
        case .up: "swipeUp"
        case .down: "swipeDown"
        case .left: "swipeLeft"
        case .right: "swipeRight"
        }
    }
}
