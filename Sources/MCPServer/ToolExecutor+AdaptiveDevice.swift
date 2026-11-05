import AmooCore
import MCP

extension DriverToolExecutor {
    func executeAdaptiveDevice(
        tool: String,
        arguments: [String: String],
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        if tool == "set_posture" {
            guard let raw = arguments["posture"], let posture = DevicePosture(rawValue: raw) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "posture must be closed, half_opened, or opened"
                )
            }
            let observed = try await driver.setPosture(posture)
            guard observed == posture else {
                throw ToolExecutionError(
                    code: "postcondition_failed", message: "Requested \(raw) but device reports \(observed.rawValue)"
                )
            }
            var fields = await deviceObservation(driver: driver)
            fields["posture"] = .string(observed.rawValue)
            fields["verified"] = .bool(true)
            fields["postcondition_verified"] = .bool(false)
            fields["outcome_status"] = .string("inconclusive")
            return ToolResult(
                content: "Posture verified: \(observed.rawValue). Screen: \(fields["screen_state"] ?? .null);"
                    + " foreground: \(fields["foreground_app_id"] ?? .null). App state remains unverified;"
                    + " re-query after the display transition.",
                structuredContent: .object(fields)
            )
        }
        guard let raw = arguments["preset"], let preset = DisplayPreset(rawValue: raw) else {
            throw ToolExecutionError(code: "invalid_argument", message: "preset must be phone, unfolded, or tablet")
        }
        let observed = try await driver.setDisplayPreset(preset)
        var fields = await deviceObservation(driver: driver)
        fields.merge([
            "preset": .string(raw), "verified": .bool(true),
            "width_pixels": .int(observed.widthPixels), "height_pixels": .int(observed.heightPixels),
            "density_dpi": .int(observed.densityDPI), "postcondition_verified": .bool(false),
            "outcome_status": .string("inconclusive")
        ], uniquingKeysWith: { _, value in value })
        return ToolResult(
            content: "Display preset verified: \(raw), \(observed.widthPixels)x\(observed.heightPixels) pixels,"
                + " \(observed.densityDPI) dpi. Re-query elements after resizing.",
            structuredContent: .object(fields)
        )
    }
}
