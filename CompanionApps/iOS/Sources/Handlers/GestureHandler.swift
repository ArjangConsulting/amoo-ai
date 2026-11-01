import CoreGraphics

/// Handles gesture-related gRPC requests by delegating to XCUITestBridge.
///
/// Points arrive relative to the display the companion reports on and are moved into the global
/// space the bridge works in; see `XCUITestBridge.displayOrigin()`. Pinch is iOS-only, where that
/// origin is always zero.
final class GestureHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) async {
        let origin = await bridge.displayOrigin()
        await bridge.swipe(
            fromX: fromX + origin.x, fromY: fromY + origin.y,
            toX: toX + origin.x, toY: toY + origin.y,
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
        let origin = await bridge.displayOrigin()
        await bridge.drag(
            fromX: fromX + origin.x, fromY: fromY + origin.y,
            toX: toX + origin.x, toY: toY + origin.y,
            durationSeconds: Double(durationMs) / 1000.0,
            holdSeconds: Double(holdMs) / 1000.0
        )
    }

    /// Returns a failure message, or nil once the pinch was delivered.
    func pinch(x: Double, y: Double, scale: Double, velocity: Double, bounds: CGRect?) async -> String? {
        await bridge.pinch(x: x, y: y, scale: scale, velocity: velocity, bounds: bounds)
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
