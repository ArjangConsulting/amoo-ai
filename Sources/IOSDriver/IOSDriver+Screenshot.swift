import AmooCore

public extension IOSDriver {
    /// Prefers the companion (XCUIScreen), which also scales and encodes on the device — simctl
    /// screenshot can time out while XCUITest is active and always returns native pixels.
    func takeScreenshot(_ options: ScreenshotRequestOptions) async throws -> ScreenshotData {
        do {
            return try await companion.takeScreenshot(options: options)
        } catch {
            return try await Self.hostScreenshot(
                backend: backend,
                device: deviceID,
                format: options.format,
                after: error
            )
        }
    }
}
