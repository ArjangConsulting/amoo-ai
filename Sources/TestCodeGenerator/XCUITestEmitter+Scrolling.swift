import StudioProtocol

extension XCUITestEmitter {
    /// Scrolls with the generated `scrollToElement` helper (up to `max_attempts`, default 8), then
    /// waits on the element so a target that never appears fails the test where it was expected.
    ///
    /// The helper is the live tool's algorithm, so a replayed test reaches rows the recording did:
    /// it scrolls straight at an element the hierarchy already holds, else pages in `direction`, and
    /// reverses once at the end of the content. A context can bind `scrollToElement` to the project's
    /// own helper with `{{element}}`, `{{direction}}`, `{{attempts}}` and `{{distance}}`.
    static func scrollToElementStatement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        let (_, variable, declaration) = try lookup(
            operation, context: context, localNames: &localNames, lookups: &lookups
        )
        let direction = operation.arguments["direction"]?.lowercased() ?? "down"
        // Validates the direction the same way every other scroll is validated.
        _ = try GestureDirection.gestureDirection(for: "scroll", rawDirection: direction)
        let attempts = operation.arguments["max_attempts"].flatMap(Int.init) ?? 8
        let distance = operation.arguments["distance"].flatMap(Double.init)
        let scroll: String
        if let template = context?.waitBindings["scrollToElement"] {
            scroll = template.replacingOccurrences(of: "{{element}}", with: variable)
                .replacingOccurrences(of: "{{direction}}", with: literal(direction))
                .replacingOccurrences(of: "{{attempts}}", with: String(attempts))
                .replacingOccurrences(of: "{{distance}}", with: distance.map { String($0) } ?? "nil")
        } else {
            let cap = distance.map { ", maximumDistance: \($0)" } ?? ""
            scroll = "scrollToElement(\(variable), direction: \(literal(direction)), maxAttempts: \(attempts)\(cap))"
        }
        return try """
        \(declaration)
        \(indent)\(scroll)
        \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
        """
    }

    /// The generated `scrollToElement`, emitted only into a test that scrolls to an element.
    ///
    /// It mirrors amoo's `scroll_to_element`: a page is 60% of the screen, capped by the recorded
    /// `distance`; an element the hierarchy already holds is dragged toward directly; a drag that
    /// moves fewer than three elements by more than two points means the content ended, and the
    /// direction reverses once. The drag is slow and holds before lifting, so the list stops where
    /// the finger does instead of flinging past rows.
    static let scrollToElementHelper = """
        private func scrollToElement(
            _ element: XCUIElement,
            direction: String = "down",
            maxAttempts: Int = 8,
            maximumDistance: CGFloat? = nil
        ) {
            func layout() -> [String: CGPoint] {
                guard let root = try? app.snapshot() else { return [:] }
                var positions: [String: CGPoint] = [:]
                var occurrences: [String: Int] = [:]
                var pending = [root]
                while let node = pending.popLast(), positions.count < 300 {
                    pending.append(contentsOf: node.children.reversed())
                    guard !node.identifier.isEmpty || !node.label.isEmpty else { continue }
                    let base = "\\(node.identifier)|\\(node.label)"
                    let occurrence = occurrences[base, default: 0]
                    occurrences[base] = occurrence + 1
                    positions["\\(base)|\\(occurrence)"] = CGPoint(x: node.frame.midX, y: node.frame.midY)
                }
                return positions
            }
            func contentMoved(from before: [String: CGPoint], to after: [String: CGPoint]) -> Bool {
                let shifted = after.filter { key, point in
                    guard let old = before[key] else { return true }
                    return abs(old.x - point.x) > 2 || abs(old.y - point.y) > 2
                }.count
                let vanished = before.keys.filter { after[$0] == nil }.count
                return shifted + vanished >= min(3, max(1, max(before.count, after.count)))
            }
            let opposite = ["down": "up", "up": "down", "left": "right", "right": "left"]
            let screen = app.frame
            var paging = direction
            var reversed = false
            for _ in 0 ..< maxAttempts {
                if element.exists, element.isHittable { return }
                let vertical = paging == "up" || paging == "down"
                var travel = (vertical ? screen.height : screen.width) * 0.6
                if let maximumDistance {
                    travel = min(travel, maximumDistance)
                }
                var toward = paging
                if element.exists, !element.frame.isEmpty {
                    let offset = vertical ? element.frame.midY - screen.midY : element.frame.midX - screen.midX
                    if abs(offset) >= 10 {
                        travel = min(abs(offset), travel)
                        toward = vertical ? (offset > 0 ? "down" : "up") : (offset > 0 ? "right" : "left")
                    }
                }
                let finger: CGVector = switch toward {
                case "down": CGVector(dx: 0, dy: -travel)
                case "up": CGVector(dx: 0, dy: travel)
                case "right": CGVector(dx: -travel, dy: 0)
                default: CGVector(dx: travel, dy: 0)
                }
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: -finger.dx / 2, dy: -finger.dy / 2))
                let before = layout()
                start.press(
                    forDuration: 0.05,
                    thenDragTo: start.withOffset(finger),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.2
                )
                if !contentMoved(from: before, to: layout()) {
                    if reversed { return }
                    reversed = true
                    paging = opposite[paging] ?? paging
                }
            }
        }

    """

    static func gestureMethod(_ direction: GestureDirection) -> String {
        switch direction {
        case .up: "swipeUp"
        case .down: "swipeDown"
        case .left: "swipeLeft"
        case .right: "swipeRight"
        }
    }
}
