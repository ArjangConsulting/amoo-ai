/// Handles touch-related gRPC requests by delegating to XCUITestBridge.
final class TouchHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func tap(x: Double, y: Double) async {
        await bridge.tap(x: x, y: y)
    }

    func doubleTap(x: Double, y: Double) async {
        await bridge.doubleTap(x: x, y: y)
    }

    func longPress(x: Double, y: Double, durationMs: Int) async {
        await bridge.longPress(x: x, y: y, durationSeconds: Double(durationMs) / 1000.0)
    }

    func tapElement(
        id: String?,
        label: String?,
        containsText: String? = nil,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async -> Bool {
        await bridge.tapElement(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs
        )
    }
}
