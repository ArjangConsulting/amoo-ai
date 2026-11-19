import Foundation

/// Handles touch-related gRPC requests by delegating to XCUITestBridge.
///
/// Points arrive relative to the display the companion reports on and are moved into the global
/// space the bridge works in; see `XCUITestBridge.displayOrigin()`.
final class TouchHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func tap(x: Double, y: Double) async {
        let origin = await bridge.displayOrigin()
        await bridge.tap(x: x + origin.x, y: y + origin.y)
    }

    func doubleTap(x: Double, y: Double) async {
        let origin = await bridge.displayOrigin()
        await bridge.doubleTap(x: x + origin.x, y: y + origin.y)
    }

    func longPress(x: Double, y: Double, durationMs: Int) async {
        let origin = await bridge.displayOrigin()
        await bridge.longPress(x: x + origin.x, y: y + origin.y, durationSeconds: Double(durationMs) / 1000.0)
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

    /// XCUITest's hit test for one element; `frame` arrives in display space like every point.
    func hitTest(
        id: String,
        label: String,
        frame: CGRect?,
        bundleID: String?,
        candidateBundleIDs: [String]
    ) async -> XCUITestBridge.HitTestOutcome {
        let origin = await bridge.displayOrigin()
        return await bridge.hitTest(
            id: id,
            label: label,
            frame: frame?.offsetBy(dx: origin.x, dy: origin.y),
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs
        )
    }
}
