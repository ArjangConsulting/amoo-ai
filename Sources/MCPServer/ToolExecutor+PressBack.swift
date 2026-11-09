import AmooCore
import MCP

extension DriverToolExecutor {
    /// Presses back and reports whether the app lost the foreground.
    ///
    /// Back on an app's root screen leaves the app. That is easy to do by accident (a back tap
    /// that was meant to leave a detail screen, issued once too often) and the call otherwise
    /// reports plain success, so the next step runs against the launcher. The check compares the
    /// foreground app before and after and says so when it changed.
    func executePressBack(driver: any PlatformDriver) async throws -> ToolResult {
        let before = try? await driver.currentApp().bundleID
        try await driver.pressBack()
        guard let before else {
            return .success("Pressed back")
        }
        let after = try? await driver.currentApp().bundleID
        var fields: [String: Value] = ["foreground_bundle_id": after.map(Value.string) ?? .null]
        guard let after else {
            return .success(
                "Pressed back; the foreground app could not be read afterwards.",
                structuredContent: .object(fields)
            )
        }
        let left = after != before
        fields["foreground_changed"] = .bool(left)
        fields["left_app"] = .bool(left)
        guard left else {
            return .success("Pressed back", structuredContent: .object(fields))
        }
        return .success(
            "Pressed back, and the foreground app changed from \(before) to \(after): back on the root screen"
                + " leaves the app. Do not press back on the home screen; relaunch the app or use an in-app control.",
            structuredContent: .object(fields)
        )
    }
}
