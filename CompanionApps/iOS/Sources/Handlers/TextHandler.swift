/// Handles text-related gRPC requests by delegating to XCUITestBridge.
final class TextHandler: @unchecked Sendable {
    private let bridge: XCUITestBridge

    init(bridge: XCUITestBridge) {
        self.bridge = bridge
    }

    func typeText(_ text: String) async {
        await bridge.typeText(text)
    }

    func clearText(characterCount: Int?) async {
        await bridge.clearText(characterCount: characterCount)
    }

    func setText(
        id: String?,
        label: String?,
        containsText: String?,
        text: String,
        bundleID: String?,
        candidateBundleIDs: [String]
    ) async -> Bool {
        await bridge.setText(
            id: id,
            label: label,
            containsText: containsText,
            text: text,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs
        )
    }
}
