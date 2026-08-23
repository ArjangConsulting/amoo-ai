/// Handles gesture-related gRPC requests by delegating to XCUITestBridge.
final class GestureHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async {
        await bridge.swipe(
            fromX: fromX, fromY: fromY,
            toX: toX, toY: toY,
            durationSeconds: Double(durationMs) / 1000.0
        )
    }

    func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int
    ) async {
        await bridge.drag(
            fromX: fromX, fromY: fromY,
            toX: toX, toY: toY,
            durationSeconds: Double(durationMs) / 1000.0,
            holdSeconds: Double(holdMs) / 1000.0
        )
    }

    func scroll(direction: ScrollDirection, distance: Double) async {
        await bridge.scroll(direction: direction, distance: distance)
    }

    /// Returns `false` when `id`/`label`/`containsText` was supplied but resolved no element, so
    /// the caller can surface a real failure instead of reporting success for a swipe that either
    /// did nothing or — previously — silently landed on the wrong element. See
    /// `XCUITestBridge.swipeInDirection` for why a resolution miss must not fall back to a
    /// generic whole-target swipe.
    @discardableResult
    func swipeInDirection(
        direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) async -> Bool {
        await bridge.swipeInDirection(direction, id: id, label: label, containsText: containsText)
    }
}
