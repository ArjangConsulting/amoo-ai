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
            return ToolResult(
                content: "Posture verified: \(observed.rawValue). Re-query elements after the display transition.",
                structuredContent: .object(["posture": .string(observed.rawValue), "verified": .bool(true)])
            )
        }
        guard let raw = arguments["preset"], let preset = DisplayPreset(rawValue: raw) else {
            throw ToolExecutionError(code: "invalid_argument", message: "preset must be phone, unfolded, or tablet")
        }
        let observed = try await driver.setDisplayPreset(preset)
        return ToolResult(
            content: "Display preset verified: \(raw), \(observed.widthPixels)x\(observed.heightPixels) pixels,"
                + " \(observed.densityDPI) dpi. Re-query elements after resizing.",
            structuredContent: .object([
                "preset": .string(raw), "verified": .bool(true),
                "width_pixels": .int(observed.widthPixels), "height_pixels": .int(observed.heightPixels),
                "density_dpi": .int(observed.densityDPI)
            ])
        )
    }
}
