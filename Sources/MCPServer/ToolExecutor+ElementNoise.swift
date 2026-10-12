import AmooCore

extension DriverToolExecutor {
    /// True when the call names no selector, so it lists the whole screen. Only that listing is
    /// noisy enough to filter: a selector already asks for specific elements.
    static func listsEverything(_ arguments: [String: String]) -> Bool {
        ["id", "label", "contains_text", "description", "parent_id"].allSatisfy { arguments[$0]?.isEmpty ?? true }
    }

    /// Drops elements that add nothing to a whole-screen listing:
    /// - static text with no identifier of its own that repeats the label of a control whose frame
    ///   contains it (the label child of a button), which lists every button twice;
    /// - scroll bars, matched by the system's English accessibility label, which have no use as a
    ///   target and appear on every scrolling screen.
    ///
    /// The parent control is always kept, so nothing becomes unreachable.
    static func removingNoise(_ elements: [ElementInfo]) -> [ElementInfo] {
        let controls = elements.filter { $0.type != .staticText && !$0.label.isEmpty }
        return elements.filter { element in
            if isScrollBar(element) {
                return false
            }
            guard element.type == .staticText, element.id.isEmpty, !element.label.isEmpty,
                  let frame = element.frame else { return true }
            return !controls.contains { control in
                control.label == element.label && control.frame.map { contains($0, frame) } == true
            }
        }
    }

    private static func isScrollBar(_ element: ElementInfo) -> Bool {
        element.id.isEmpty
            && (element.label.hasPrefix("Vertical scroll bar") || element.label.hasPrefix("Horizontal scroll bar"))
    }

    private static func contains(_ outer: Rect, _ inner: Rect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width
            && inner.y + inner.height <= outer.y + outer.height
    }
}
