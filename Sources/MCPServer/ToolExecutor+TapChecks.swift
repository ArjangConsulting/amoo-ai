import AmooCore
import MCP

/// Why a tap would not reach the element it was aimed at.
enum TapBlock: Equatable {
    /// The tap point lies outside the app's visible window.
    case offScreen(Point)
    /// Another control is painted over the tap point.
    case covered(by: String)

    var explanation: String {
        switch self {
        case let .offScreen(point):
            "its tap point (\(Int(point.x)), \(Int(point.y))) is outside the visible screen"
        case let .covered(blocker):
            "it is covered by \(blocker)"
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

    static func block(for target: ElementInfo, at point: Point, in root: ViewNode) -> TapBlock? {
        if let window = root.frame, !contains(window, point) {
            return .offScreen(point)
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
    /// Whether `tap_element` should look at the hierarchy before tapping.
    ///
    /// `check_hittable` forces it on or off. Without it the check runs only while the keyboard is
    /// up — the one overlay that routinely covers a control — because a hierarchy snapshot is the
    /// most expensive call on a dense screen.
    func shouldCheckHittable(arguments: [String: String], driver: any PlatformDriver) async -> Bool {
        if let raw = arguments["check_hittable"], let flag = boolArgument(raw) {
            return flag
        }
        return await (try? driver.isKeyboardVisible()) ?? false
    }

    /// A refusal for a tap that would miss `matched`, or `nil` when it looks safe to tap.
    func tapBlockError(
        matched: ElementInfo,
        point: Point,
        driver: any PlatformDriver,
        appID: String?
    ) async -> ToolResult? {
        guard let hierarchy = try? await driver.getViewHierarchy(appID: appID),
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
