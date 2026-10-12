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
            "its tap point (\(geometryNumber(point.x)), \(geometryNumber(point.y))) is outside the visible screen"
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
    /// How `tap_element` uses the hierarchy around a tap: reads it before to refuse a tap that would
    /// miss, and again after to report a tap that changed nothing.
    ///
    /// `true` insists, `false` skips. By default both are best effort: a hierarchy read is ~0.1s on an
    /// ordinary screen, so worth doing on every tap, but on a very dense one (accessibility text
    /// sizes) it can take far longer — so the default gives up after the budget and carries on
    /// unchecked rather than slowing every call.
    enum HierarchyCheck: Equatable {
        case off
        case required
        case bestEffort(milliseconds: Int)
    }

    func hittableCheck(arguments: [String: String]) -> HierarchyCheck {
        check(arguments["check_hittable"], budget: arguments["hittable_timeout_ms"])
    }

    func effectCheck(arguments: [String: String]) -> HierarchyCheck {
        check(arguments["check_effect"], budget: arguments["effect_timeout_ms"])
    }

    private func check(_ flag: String?, budget: String?) -> HierarchyCheck {
        if let flag, let value = boolArgument(flag) {
            return value ? .required : .off
        }
        let milliseconds = budget.flatMap(Int.init) ?? 1500
        return milliseconds > 0 ? .bestEffort(milliseconds: milliseconds) : .off
    }

    private func readHierarchy(
        _ check: HierarchyCheck,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> ViewNode? {
        switch check {
        case .off:
            nil
        case .required:
            try await OperationDeadline.read(until: .now + .seconds(12)) {
                try await driver.getViewHierarchy(appID: appID)
            }
        case let .bestEffort(milliseconds):
            await Self.withinBudget(milliseconds: milliseconds) {
                try? await driver.getViewHierarchy(appID: appID)
            }
        }
    }

    /// The two hierarchy checks of one `tap_element` call.
    struct TapChecks {
        var hittable: HierarchyCheck
        var effect: HierarchyCheck
    }

    func tapChecks(arguments: [String: String]) -> TapChecks {
        TapChecks(hittable: hittableCheck(arguments: arguments), effect: effectCheck(arguments: arguments))
    }

    /// What `tapPreflight` found before the tap.
    struct TapPreflight {
        var refusal: ToolResult?
        /// The hierarchy read for the check, kept as the "before" picture for the effect check.
        var hierarchy: ViewNode?
    }

    /// Reads the hierarchy once and refuses a tap that would miss `matched`.
    func tapPreflight(
        matched: ElementInfo,
        point: Point?,
        checks: TapChecks,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> TapPreflight {
        let (hittable, effect) = (checks.hittable, checks.effect)
        // One read serves both checks; the stricter mode decides how hard to try.
        let mode: HierarchyCheck = switch (hittable, effect) {
        case (.required, _), (_, .required): .required
        case let (.bestEffort(a), .bestEffort(b)): .bestEffort(milliseconds: max(a, b))
        case let (.bestEffort(a), .off): .bestEffort(milliseconds: a)
        case let (.off, .bestEffort(b)): .bestEffort(milliseconds: b)
        case (.off, .off): .off
        }
        try Task.checkCancellation()
        if hittable == .required, point == nil {
            return TapPreflight(
                refusal: .error("Hittability cannot be checked: the element has no tap point."),
                hierarchy: nil
            )
        }
        guard let hierarchy = try await readHierarchy(mode, driver: driver, appID: appID) else {
            return TapPreflight(refusal: nil, hierarchy: nil)
        }
        guard hittable != .off, let point,
              let block = TapHittability.block(for: matched, at: point, in: hierarchy)
        else { return TapPreflight(refusal: nil, hierarchy: hierarchy) }
        let name = preferredElementName(label: matched.label, id: matched.id) ?? matched.id
        let refusal = ToolResult.error(
            "tap_element failed: '\(name)' would not receive the tap because \(block.explanation)."
                + " Dismiss the overlay (keyboard, sheet) or scroll the element into view, then retry,"
                + " or pass check_hittable=false to tap the point anyway."
        )
        return TapPreflight(refusal: refusal, hierarchy: hierarchy)
    }

    /// Whether the screen changed within the effect budget after a tap: compares hierarchy
    /// fingerprints, polling briefly so a transition still animating is not mistaken for no change.
    func screenChanged(
        since before: ViewNode,
        check: HierarchyCheck,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> Bool? {
        guard check != .off else { return nil }
        let reference = Self.hierarchyFingerprint(before)
        let settleMilliseconds = 800
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(settleMilliseconds))
        var observed = false
        repeat {
            try Task.checkCancellation()
            let snapshot: ViewNode?
            do {
                snapshot = try await OperationDeadline.read(until: deadline) {
                    try await self.readHierarchy(check, driver: driver, appID: appID)
                }
            } catch is OperationDeadline.DeadlineExceeded { return observed ? false : nil }
            guard let after = snapshot else {
                return observed ? false : nil
            }
            observed = true
            if Self.hierarchyFingerprint(after) != reference {
                return true
            }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        return false
    }

    /// Ids, labels, values, geometry and state of the first 800 nodes: anything a tap could change.
    static func hierarchyFingerprint(_ root: ViewNode) -> String {
        var parts: [String] = []
        func walk(_ node: ViewNode) {
            guard parts.count < 800 else { return }
            let frame = node.frame
                .map {
                    [$0.x, $0.y, $0.width, $0.height].map(geometryNumber).joined(separator: ",")
                } ?? "-"
            parts.append("\(node.id)|\(node.label)|\(node.value ?? "")|\(frame)|\(node.isEnabled)|\(node.isVisible)")
            node.children.forEach(walk)
        }
        walk(root)
        return parts.joined(separator: "\n")
    }
}

extension DriverToolExecutor {
    /// Runs `operation`, or returns `nil` if it has not finished within `milliseconds`.
    static func withinBudget<T: Sendable>(
        milliseconds: Int,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        try? await OperationDeadline.read(until: .now + .milliseconds(milliseconds)) {
            await operation()
        }
    }

    /// What `tap_element` knew before tapping, for the result.
    struct TapOutcomeContext {
        var matched: ElementInfo
        var foregroundBefore: String?
        var hierarchyBefore: ViewNode?
        var effect: HierarchyCheck
        var appID: String?
        var hittabilityChecked = false
    }

    /// Builds the `tap_element` success result, flagging taps that landed somewhere unexpected.
    ///
    /// `verified` still means the target was resolved, visible and enabled before the tap. What
    /// the tap did is reported separately: `foreground_changed` when another app (Siri, a system
    /// sheet) took over, and `observable_change` — "No observable change" in the text — when the
    /// screen is identical before and after.
    func tapElementResult(_ context: TapOutcomeContext, driver: any PlatformDriver) async throws -> ToolResult {
        let matched = context.matched
        let name = "[\(matched.id)] \(matched.label)"
        var notes: [String] = []
        var fields: [String: Value] = [
            "verified": .bool(true),
            "hittability_checked": .bool(context.hittabilityChecked),
            "element_id": .string(matched.id),
            "element_label": .string(matched.label)
        ]
        if !context.hittabilityChecked {
            notes.append("Hittability was not checked.")
        }
        if let foregroundBefore = context.foregroundBefore,
           let foregroundAfter = try? await driver.currentApp().bundleID {
            fields["foreground_bundle_id"] = .string(foregroundAfter)
            fields["foreground_changed"] = .bool(foregroundAfter != foregroundBefore)
            if foregroundAfter != foregroundBefore {
                notes.append("Foreground app changed from \(foregroundBefore) to \(foregroundAfter) after the tap.")
            }
        }
        if let before = context.hierarchyBefore,
           let changed = try await screenChanged(
               since: before, check: context.effect, driver: driver, appID: context.appID
           ) {
            fields["observable_change"] = .bool(changed)
            if !changed {
                notes.append("No observable change: the screen is identical before and after the tap.")
            }
        }
        let message = (["Tapped verified element \(name)"] + notes).joined(separator: "\n")
        return .success(message, structuredContent: .object(fields))
    }
}
