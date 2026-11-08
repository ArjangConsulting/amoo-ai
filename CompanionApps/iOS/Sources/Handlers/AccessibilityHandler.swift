import CoreGraphics
import Foundation

/// Handles accessibility query gRPC requests by delegating to XCUITestBridge.
final class AccessibilityHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func findElements(
        id: String?,
        label: String?,
        containsText: String?,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = [],
        labeledOnly: Bool = false
    ) async -> [ElementSnapshot] {
        let elements = await bridge.findElements(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs,
            labeledOnly: labeledOnly
        )
        guard let delta = await displayLocalDelta() else { return elements }
        return elements.map { $0.translated(by: delta) }
    }

    func getViewHierarchy(bundleID: String? = nil, candidateBundleIDs: [String] = []) async -> ViewNodeSnapshot {
        let hierarchy = await bridge.getViewHierarchy(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
        guard let delta = await displayLocalDelta() else { return hierarchy }
        return hierarchy.translated(by: delta)
    }

    /// The shift from the bridge's global space to the reported display's own points, or nil when
    /// the two coincide, as on iOS and a Mac's main display.
    private func displayLocalDelta() async -> CGVector? {
        let origin = await bridge.displayOrigin()
        guard origin != .zero else { return nil }
        return CGVector(dx: -origin.x, dy: -origin.y)
    }

    func isKeyboardVisible() async -> Bool {
        await bridge.isKeyboardVisible()
    }

    func currentAppBundleID() async -> String? {
        await bridge.currentAppBundleID()
    }

    func targetAppBundleID() async -> String? {
        await bridge.boundTargetBundleID()
    }

    func setTargetApp(bundleID: String?) async {
        await bridge.setTargetApp(bundleID: bundleID)
    }

    func appState(appID: String) async -> String {
        await bridge.appState(appID: appID)
    }

    func takeScreenshot() async -> Data {
        await bridge.takeScreenshot()
    }

    func captureScreen(fraction: Double, pointResolution: Bool, jpegQuality: Double?) async -> CapturedScreen {
        await bridge.captureScreen(fraction: fraction, pointResolution: pointResolution, jpegQuality: jpegQuality)
    }

    func screenInfo() async -> (points: CGSize, pixels: CGSize, scale: Double) {
        await bridge.screenInfo()
    }
}
