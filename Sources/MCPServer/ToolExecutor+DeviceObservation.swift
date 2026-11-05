import AmooCore
import MCP

extension DriverToolExecutor {
    /// Bounded device facts observed together after a display transition or capture.
    func deviceObservation(driver: any PlatformDriver) async -> [String: Value] {
        let deadline = ContinuousClock.now + .seconds(3)
        async let state = try? OperationDeadline.read(until: deadline) { try await driver.screenState() }
        async let app = try? OperationDeadline.read(until: deadline) { try await driver.currentApp() }
        async let geometry = try? OperationDeadline.read(until: deadline) { try await driver.screenGeometry() }
        let (screenState, currentApp, screen) = await (state, app, geometry)
        var fields: [String: Value] = [
            "screen_state": .string(screenState?.rawValue ?? "unknown"),
            "foreground_app_id": .string(currentApp?.bundleID ?? "unknown"),
            "target_app_id": .string(currentApp?.targetBundleID ?? "unknown")
        ]
        if let screen {
            fields["viewport"] = .object([
                "width_pixels": .double(screen.widthPixels), "height_pixels": .double(screen.heightPixels),
                "width_points": .double(screen.widthPoints), "height_points": .double(screen.heightPoints),
                "scale": .double(screen.scale)
            ])
        }
        return fields
    }
}
