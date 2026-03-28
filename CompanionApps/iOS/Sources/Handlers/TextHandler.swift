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
}
