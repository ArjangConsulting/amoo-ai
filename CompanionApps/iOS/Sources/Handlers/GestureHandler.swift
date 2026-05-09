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

    func scroll(direction: ScrollDirection, distance: Double) async {
        await bridge.scroll(direction: direction, distance: distance)
    }

    func swipeInDirection(
        direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) async {
        await bridge.swipeInDirection(direction, id: id, label: label, containsText: containsText)
    }
}
