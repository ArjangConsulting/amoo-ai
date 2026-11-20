import AmooCore

/// `parent_id`: restrict a query to the descendants of one element.
///
/// The gRPC request carries a parent selector, but neither companion reads it, so a scoped query was
/// answered as if unscoped, and `assert_visible id=day parent_id=other-month` passed on a day that
/// was not under that parent. Scoping is therefore applied here, from the view hierarchy the
/// companion already provides, before any constraint is evaluated.
extension DriverToolExecutor {
    /// The elements matching `selector` within its `parentSelector`'s subtree, in the device's order.
    ///
    /// Without a parent this is exactly `driver.findElements`. With one, the parent must resolve to a
    /// single element (several is `ambiguous_selector`, none yields no matches) and only its
    /// descendants — never the parent itself — are candidates.
    func findScopedElements(
        _ selector: ElementSelector,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> [ElementInfo] {
        guard case let .selector(parent)? = selector.parentSelector else {
            return try await driver.findElements(selector, appID: appID)
        }
        var unscoped = selector
        unscoped.parentSelector = nil

        let tree: ViewNode
        do {
            tree = try await driver.getViewHierarchy(appID: appID)
        } catch {
            throw ToolExecutionError(
                code: "scope_unavailable",
                message: "parent_id could not be applied because the view hierarchy is unavailable: \(error)."
                    + " Drop parent_id, or retry once the app is responsive."
            )
        }
        let roots = Self.nodes(in: tree, matching: parent)
        guard !roots.isEmpty else { return [] }
        guard roots.count == 1, let root = roots.first else {
            throw ToolExecutionError(
                code: "ambiguous_selector",
                message: "parent_id matched \(roots.count) elements; it must name exactly one."
                    + " Use a more specific parent id."
            )
        }
        let inside = Set(Self.descendants(of: root).map(Self.scopeKey))
        return try await driver.findElements(unscoped, appID: appID).filter { inside.contains(Self.scopeKey($0)) }
    }

    private static func nodes(in tree: ViewNode, matching selector: ElementSelector) -> [ViewNode] {
        var found: [ViewNode] = []
        var pending = [tree]
        while let node = pending.popLast() {
            let idMatches = selector.id.map { node.id == $0 } ?? true
            let labelMatches = selector.label.map { node.label == $0 } ?? true
            let textMatches = selector.containsText.map { node.label.contains($0) } ?? true
            let constrained = selector.id != nil || selector.label != nil || selector.containsText != nil
            if constrained, idMatches, labelMatches, textMatches {
                found.append(node)
            }
            pending.append(contentsOf: node.children)
        }
        return found
    }

    private static func descendants(of node: ViewNode) -> [ViewNode] {
        var found: [ViewNode] = []
        var pending = node.children
        while let next = pending.popLast() {
            found.append(next)
            pending.append(contentsOf: next.children)
        }
        return found
    }

    /// Identifies a node across the hierarchy and a flat query, which are separate reads of the screen.
    private static func scopeKey(_ node: ViewNode) -> String {
        scopeKey(id: node.id, label: node.label, frame: node.frame)
    }

    private static func scopeKey(_ element: ElementInfo) -> String {
        scopeKey(id: element.id, label: element.label, frame: element.frame)
    }

    /// The hierarchy names an element with no identifier by its label, while a flat query reports an
    /// empty identifier, so an identifier-less element is keyed by its label on both sides.
    private static func scopeKey(id: String, label: String, frame: Rect?) -> String {
        func round(_ value: Double) -> Int {
            Int((value * 2).rounded())
        }
        let box = frame.map { "\(round($0.x)),\(round($0.y)),\(round($0.width)),\(round($0.height))" } ?? "-"
        return "\(id.isEmpty ? label : id)|\(box)"
    }
}
