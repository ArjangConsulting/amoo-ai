import AmooCore
import MCP

/// Why a tap would not reach the element it was aimed at.
enum TapBlock: Equatable {
    /// The tap point lies outside the app's visible window.
    case offScreen(Point)
    /// Another control is painted over the tap point.
    case covered(by: String)
    /// A container that clips its content (tab bar, scroll view, sheet) ends before the tap point.
    case clipped(by: String)

    var explanation: String {
        switch self {
        case let .offScreen(point):
            "its tap point (\(Int(point.x)), \(Int(point.y))) is outside the visible screen"
        case let .covered(blocker):
            "it is covered by \(blocker)"
        case let .clipped(container):
            "it lies outside \(container), which clips it"
        }
    }
}

/// Decides, from one hierarchy snapshot, whether a tap at `point` would land on `target`.
///
/// `tap_element` reports "verified" once it has resolved a visible, enabled element, which says
/// nothing about what is painted on top: a numeric keypad over the control, a segment clipped
/// off-screen by its container, or a tab outside the pill that holds it all dispatched a tap that
/// hit something else. The walk follows paint order — a later sibling covers an earlier one — and
/// only counts controls (buttons, fields, sheets…) as covering, so a transparent container or a
/// decorative image over the target is not a false alarm.
enum TapHittability {
    private static let covering: Set<ElementType> = [
        .button, .textField, .switchControl, .slider, .picker, .alert, .sheet, .tabBar, .navigationBar
    ]

    /// Containers whose frame bounds what is visible inside them. An element that lies beyond one is
    /// scrolled out or clipped, whatever its own frame says.
    private static let clipping: Set<ElementType> = [
        .tabBar, .scrollView, .table, .collectionView, .navigationBar, .sheet, .alert
    ]

    static func block(for target: ElementInfo, at point: Point, in root: ViewNode) -> TapBlock? {
        if let window = root.frame, !contains(window, point) {
            return .offScreen(point)
        }
        if let container = clippingAncestor(of: target, containing: point, in: root) {
            return .clipped(by: describe(container))
        }
        var order: [(node: ViewNode, insideTarget: Bool)] = []
        collect(root, target: target, insideTarget: false, into: &order)
        guard let targetIndex = order.firstIndex(where: { isTarget($0.node, target) }) else { return nil }
        for entry in order[(targetIndex + 1)...].reversed()
            where !entry.insideTarget && entry.node.isVisible && entry.node.type.map(covering.contains) == true {
            if let frame = entry.node.frame, contains(frame, point) {
                return .covered(by: describe(entry.node))
            }
        }
        return nil
    }

    /// The nearest clipping ancestor of `target` whose frame does not contain `point`, if any.
    private static func clippingAncestor(
        of target: ElementInfo,
        containing point: Point,
        in root: ViewNode
    ) -> ViewNode? {
        func search(_ node: ViewNode, path: [ViewNode]) -> [ViewNode]? {
            if isTarget(node, target) {
                return path
            }
            for child in node.children {
                if let found = search(child, path: path + [node]) {
                    return found
                }
            }
            return nil
        }
        guard let ancestors = search(root, path: []) else { return nil }
        return ancestors.reversed().first { node in
            guard let type = node.type, clipping.contains(type), let frame = node.frame else { return false }
            return !contains(frame, point)
        }
    }

    private static func collect(
        _ node: ViewNode,
        target: ElementInfo,
        insideTarget: Bool,
        into order: inout [(node: ViewNode, insideTarget: Bool)]
    ) {
        order.append((node, insideTarget))
        let nowInside = insideTarget || isTarget(node, target)
        for child in node.children {
            collect(child, target: target, insideTarget: nowInside, into: &order)
        }
    }

    private static func isTarget(_ node: ViewNode, _ target: ElementInfo) -> Bool {
        node.id == target.id && node.label == target.label && node.frame == target.frame
    }

    private static func contains(_ frame: Rect, _ point: Point) -> Bool {
        point.x >= frame.x && point.x <= frame.x + frame.width
            && point.y >= frame.y && point.y <= frame.y + frame.height
    }

    private static func describe(_ node: ViewNode) -> String {
        let name = !node.id.isEmpty ? node.id : node.label
        let type = node.type?.rawValue ?? "element"
        return name.isEmpty ? "a \(type)" : "\(type) '\(name)'"
    }
}

extension DriverToolExecutor {
    /// How `tap_element` checks the tap point against the hierarchy before tapping.
    ///
    /// `check_hittable=true` insists on it, `false` skips it. By default the check is best effort: a
    /// hierarchy read is ~0.1s on an ordinary screen, so it is worth running on every tap, but on a
    /// very dense one (accessibility text sizes) it can take far longer — so the default gives up
    /// after `hittable_timeout_ms` (1500) and taps unchecked rather than slowing every call.
    enum HittableCheck: Equatable {
        case off
        case required
        case bestEffort(milliseconds: Int)
    }

    func hittableCheck(arguments: [String: String]) -> HittableCheck {
        if let raw = arguments["check_hittable"], let flag = boolArgument(raw) {
            return flag ? .required : .off
        }
        let budget = arguments["hittable_timeout_ms"].flatMap(Int.init) ?? 1500
        return budget > 0 ? .bestEffort(milliseconds: budget) : .off
    }

    /// A refusal for a tap that would miss `matched`, or `nil` when it looks safe to tap.
    func tapBlockError(
        matched: ElementInfo,
        point: Point,
        check: HittableCheck,
        driver: any PlatformDriver,
        appID: String?
    ) async -> ToolResult? {
        let hierarchy: ViewNode?
        switch check {
        case .off:
            return nil
        case .required:
            hierarchy = try? await driver.getViewHierarchy(appID: appID)
        case let .bestEffort(milliseconds):
            hierarchy = await Self.withinBudget(milliseconds: milliseconds) {
                try? await driver.getViewHierarchy(appID: appID)
            }
        }
        guard let hierarchy,
              let block = TapHittability.block(for: matched, at: point, in: hierarchy)
        else { return nil }
        let name = preferredElementName(label: matched.label, id: matched.id) ?? matched.id
        return .error(
            "tap_element failed: '\(name)' would not receive the tap because \(block.explanation)."
                + " Dismiss the overlay (keyboard, sheet) or scroll the element into view, then retry,"
                + " or pass check_hittable=false to tap the point anyway."
        )
    }
}

extension DriverToolExecutor {
    /// Runs `operation`, or returns `nil` if it has not finished within `milliseconds`.
    static func withinBudget<T: Sendable>(
        milliseconds: Int,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return nil
            }
            var result: T?
            if let first = await group.next() {
                result = first
            }
            group.cancelAll()
            return result
        }
    }

    /// Builds the `tap_element` success result, flagging taps that landed somewhere unexpected.
    ///
    /// `verified` still means the target was resolved, visible and enabled before the tap. What
    /// the tap did is reported separately: `foreground_changed` when another app (Siri, a system
    /// sheet) took over, and with `check_effect` an `observable_change` flag so a tap that moved
    /// nothing reads as "no observable change" instead of success.
    func tapElementResult(
        matched: ElementInfo,
        foregroundBefore: String?,
        screenBefore: String?,
        checkEffect: Bool,
        driver: any PlatformDriver
    ) async -> ToolResult {
        let name = "[\(matched.id)] \(matched.label)"
        var notes: [String] = []
        var fields: [String: Value] = [
            "verified": .bool(true),
            "element_id": .string(matched.id),
            "element_label": .string(matched.label)
        ]
        if let foregroundBefore, let foregroundAfter = try? await driver.currentApp().bundleID {
            fields["foreground_bundle_id"] = .string(foregroundAfter)
            fields["foreground_changed"] = .bool(foregroundAfter != foregroundBefore)
            if foregroundAfter != foregroundBefore {
                notes.append("Foreground app changed from \(foregroundBefore) to \(foregroundAfter) after the tap.")
            }
        }
        if checkEffect {
            let screenAfter = try? await driver.getScreenContext().summary
            if let screenBefore, let screenAfter {
                let changed = screenBefore != screenAfter
                fields["observable_change"] = .bool(changed)
                if !changed {
                    notes.append("No observable change: the screen is identical before and after the tap.")
                }
            }
        }
        let message = (["Tapped verified element \(name)"] + notes).joined(separator: "\n")
        return .success(message, structuredContent: .object(fields))
    }
}
