#if os(macOS)
import CoreGraphics
import XCTest

/// The Mac display the target app is on.
///
/// A Mac's displays share one global space in points, measured from the main display's top-left
/// corner, and XCUITest frames and coordinates are in that space. A screenshot covers one display,
/// so the companion reports and accepts geometry relative to the display the target's front window
/// is on: the handlers subtract this display's origin from frames and add it back to gesture points.
/// On the main display the origin is zero and nothing changes.
struct MacHostDisplay {
    let id: CGDirectDisplayID
    /// The display's bounds in global points.
    let bounds: CGRect
}

extension XCUITestBridge {
    /// The display under the centre of the target's front window, or the main display when the
    /// target has no window or its centre is on no display.
    func macHostDisplay() -> MacHostDisplay {
        var id = CGMainDisplayID()
        if let window = macFrontWindow()?.frame.standardized, !window.isNull, !window.isEmpty {
            var found: CGDirectDisplayID = 0
            var count: UInt32 = 0
            let centre = CGPoint(x: window.midX, y: window.midY)
            if CGGetDisplaysWithPoint(centre, 1, &found, &count) == .success, count > 0 {
                id = found
            }
        }
        let display = MacHostDisplay(id: id, bounds: CGDisplayBounds(id))
        if display.id != Self.lastLoggedDisplayID {
            Self.lastLoggedDisplayID = display.id
            print("macOS host display \(display.id) at \(display.bounds)")
        }
        return display
    }

    /// The display last reported in the log, so a change is logged once rather than on every call.
    nonisolated(unsafe) private static var lastLoggedDisplayID: CGDirectDisplayID?

    /// The XCUIScreen for ``macHostDisplay()``, matched on XCTest's private display identifier.
    func macHostScreen(for display: MacHostDisplay) -> XCUIScreen {
        XCUIScreen.screens.first { Self.displayID(of: $0) == UInt(display.id) } ?? XCUIScreen.main
    }

    /// The main window of the gesture target, falling back to the frontmost app's.
    ///
    /// Gestures are anchored on a window because a Mac app's own frame is infinite: a coordinate
    /// taken against the app resolves to NaN and the click lands nowhere, on every display.
    ///
    /// The largest window wins rather than `firstMatch`, whose order is not stable and which can
    /// be a thin strip such as the app's menu-bar extra on the main display; anchoring on that put
    /// the host display on the wrong screen whenever the app's real window was on another.
    func macFrontWindow() -> XCUIElement? {
        for app in [gestureTarget(), resolvedTargetApp(bundleID: nil, candidateBundleIDs: [])] {
            let windows = app.windows.allElementsBoundByIndex.prefix(Self.maxWindowsConsidered)
            let candidates = windows.compactMap { window -> (element: XCUIElement, area: CGFloat)? in
                let frame = window.frame.standardized
                guard !frame.isNull, !frame.isEmpty, frame.height > Self.minWindowHeight else { return nil }
                return (window, frame.width * frame.height)
            }
            if let largest = candidates.max(by: { $0.area < $1.area }) {
                return largest.element
            }
        }
        return nil
    }

    /// Bounds the per-call window walk; each window's frame is an IPC round trip.
    private static let maxWindowsConsidered = 8

    /// Shorter than this is a strip (menu bar, status item), not a window an app is shown in.
    private static let minWindowHeight: CGFloat = 60

    /// Scrolls with the wheel at `point` (global points) so the content moves by `delta`.
    ///
    /// A mouse drag on a Mac selects text or moves things rather than scrolling, so every scroll
    /// and directional swipe goes through the wheel. A negative `dy` moves content up, revealing
    /// what is below, which is what a finger swiping up does on a phone.
    func macScroll(at point: CGPoint, by delta: CGVector) {
        gestureCoordinate(x: point.x, y: point.y).scroll(byDeltaX: delta.dx, deltaY: delta.dy)
    }
}
#endif
