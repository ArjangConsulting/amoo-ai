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
        candidateBundleIDs: [String] = []
    ) async -> [ElementSnapshot] {
        await bridge.findElements(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs
        )
    }

    func getViewHierarchy(bundleID: String? = nil, candidateBundleIDs: [String] = []) async -> ViewNodeSnapshot {
        await bridge.getViewHierarchy(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
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

    func takeScreenshot() async -> Data {
        await bridge.takeScreenshot()
    }
}
