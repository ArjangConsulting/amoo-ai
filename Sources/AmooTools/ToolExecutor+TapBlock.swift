import AmooCore
import AmooLogging

private let tapCheckLogger = AmooLogger.forType(TapHittability.self)

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

    /// Whether the block is inferred from frames and tree order alone, which cannot see paint order:
    /// a SwiftUI overlay can come before the list it floats over in the accessibility tree. Only
    /// these are worth confirming with the platform's own hit test; an off-screen point is plain
    /// geometry.
    var isInferredFromTreeOrder: Bool {
        switch self {
        case .offScreen: false
        case .covered, .clipped: true
        }
    }
}

extension DriverToolExecutor {
    /// How long the device hit test confirming a suspected block may take before the frame check's
    /// judgement stands on its own.
    static let hitTestBudgetMilliseconds = 3000

    /// The device hit test's verdict on a block the frame check suspected; `.unsupported` when the
    /// driver cannot ask, the call fails, or it overruns its budget.
    func confirmBlock(
        on element: ElementInfo,
        driver: any PlatformDriver,
        appID: String?
    ) async -> HitTestVerdict {
        tapCheckLogger.debug("Confirming suspected tap block with device hit test", context: "element_id=\(element.id)")
        let verdict = await Self.withinBudget(milliseconds: Self.hitTestBudgetMilliseconds) {
            try? await driver.hitTest(element, appID: appID)
        } ?? .unsupported
        tapCheckLogger.debug(
            "Device hit test finished", context: "element_id=\(element.id) verdict=\(verdict.rawValue)"
        )
        return verdict
    }

    /// Why a tap was refused. A block only the frame check saw is reported as possible, since tree
    /// order is not paint order; one the device hit test agreed with is reported as fact.
    static func blockedTapMessage(
        name: String,
        block: TapBlock,
        verdict: HitTestVerdict,
        gesture: (tool: String, noun: String)
    ) -> String {
        let remedy = " Dismiss the overlay (keyboard, sheet) or scroll the element into view, then retry,"
            + " or pass check_hittable=false to \(gesture.noun) the point anyway."
        guard block.isInferredFromTreeOrder, verdict != .notHittable else {
            let confirmation = block.isInferredFromTreeOrder ? " (confirmed by the device hit test)" : ""
            return "\(gesture.tool) failed: '\(name)' would not receive the \(gesture.noun) because"
                + " \(block.explanation)\(confirmation)." + remedy
        }
        let reason = verdict == .unresolved
            ? "the device hit test could not resolve the element"
            : "no device hit test was available to confirm it"
        return "\(gesture.tool) failed: '\(name)' may not receive the \(gesture.noun): frame overlap and tree"
            + " order suggest \(block.explanation), but they cannot see paint order and \(reason)."
            + " If '\(name)' is drawn on top (an overlay or floating button), pass check_hittable=false"
            + " and assert the result; otherwise dismiss the overlay (keyboard, sheet) or scroll the"
            + " element into view, then retry."
    }
}
