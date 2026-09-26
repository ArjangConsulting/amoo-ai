import AmooCore
import Foundation
import MCP

/// Checks that answer without a companion: argument names, `device_boot device_hint=…`, and leases.
/// `nil` means proceed.
func devicePreflight(_ options: DeviceCommandOptions) async -> CLIResult? {
    if let message = unknownArgumentMessage(tool: options.tool, arguments: options.arguments) {
        return CLIResult(output: message, exitCode: 1)
    }
    // `device_hint` resolution (AVD names, simulator names) lives in the CLI's bootstrapper, which
    // `amoo device` has no session manager for; without this the hint was silently ignored and
    // `driver.boot()` returned whatever device was first.
    if options.tool == "device_boot", let hint = options.arguments["device_hint"], !hint.isEmpty {
        return await runDeviceBootHint(options: options, hint: hint)
    }
    do {
        try enforceLease(deviceID: options.deviceID, lease: presentedLease(flag: options.lease))
    } catch {
        var refused = deviceCommandResult(options: options, content: "\(error)", isError: true, structured: nil)
        refused.exitCode = 3
        return refused
    }
    return nil
}

private func runDeviceBootHint(options: DeviceCommandOptions, hint: String) async -> CLIResult {
    let bootstrapper = DefaultSessionBootstrapper(
        iOSCompanionManager: CompanionManager(),
        androidCompanionManager: AndroidCompanionManager()
    )
    do {
        let info = try await bootstrapper.bootDevice(hint: hint, platform: options.platform)
        return deviceCommandResult(
            options: options,
            content: "Device booted and verified: \(info.name) (\(info.id))",
            isError: false,
            structured: .object(["verified": .bool(true), "device_id": .string(info.id)])
        )
    } catch {
        return deviceCommandResult(
            options: options,
            content: "device_boot failed: \(error)",
            isError: true,
            structured: nil
        )
    }
}
