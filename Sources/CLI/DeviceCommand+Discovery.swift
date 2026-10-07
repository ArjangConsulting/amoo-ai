import AmooCore
import MCP

/// Host-side discovery must not require a running companion or a device lease.
func discoverCommandDevices(platform: Platform?, includeOffline: Bool) async throws -> [DeviceInfo] {
    let bootstrapper = DefaultSessionBootstrapper(
        iOSCompanionManager: CompanionManager(),
        androidCompanionManager: AndroidCompanionManager()
    )
    return try await bootstrapper.listDevices(platform: platform, includeOffline: includeOffline)
}

func runDeviceDiscovery(
    options: DeviceCommandOptions,
    discover: (Platform?, Bool) async throws -> [DeviceInfo]
) async -> CLIResult {
    let platform: Platform?
    if let raw = options.arguments["platform"] {
        guard let parsed = Platform(rawValue: raw.lowercased()) else {
            return deviceCommandResult(
                options: options,
                content: "Unknown platform '\(raw)'. Expected 'ios' or 'android'.",
                isError: true,
                structured: nil
            )
        }
        platform = parsed
    } else {
        platform = nil
    }
    do {
        let devices = try await discover(platform, options.arguments["include_offline"] == "true")
        let rows: [Value] = devices.map { device in
            .object([
                "id": .string(device.id),
                "name": .string(device.name),
                "platform": .string(device.platform.rawValue),
                "os_version": .string(device.osVersion),
                "state": .string(device.state.rawValue)
            ])
        }
        let lines = devices.map { "[\($0.platform.rawValue)] \($0.name) (\($0.id)) — \($0.state.rawValue)" }
        return deviceCommandResult(
            options: options,
            content: lines.isEmpty ? "No devices found." : lines.joined(separator: "\n"),
            isError: false,
            structured: .object(["devices": .array(rows)])
        )
    } catch {
        return deviceCommandResult(
            options: options,
            content: "list_devices failed: \(error)",
            isError: true,
            structured: nil
        )
    }
}
