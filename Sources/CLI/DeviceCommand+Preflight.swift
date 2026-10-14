import AmooCore
import Foundation
import MCP
import MobileDevices

/// Checks that answer without a companion: argument names, `device_boot device_hint=…`, and leases.
/// `nil` means proceed.
func devicePreflight(
    _ options: DeviceCommandOptions,
    discoverDevices: (Platform?, Bool) async throws -> [DeviceInfo] = discoverCommandDevices
) async -> CLIResult? {
    if let message = unknownArgumentMessage(tool: options.tool, arguments: options.arguments) {
        return CLIResult(output: message, exitCode: 1)
    }
    if options.tool == "list_devices" {
        return await runDeviceDiscovery(options: options, discover: discoverDevices)
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
        return leaseRefusal(options: options, error: error)
    }
    return nil
}

/// Resolves the lease's endpoint into `options`, then runs the preflight checks; a failure is the
/// finished result to print.
func prepareDeviceCommand(_ options: DeviceCommandOptions) async -> DeviceCommandPreparation {
    switch options.applyingLease() {
    case let .failure(error):
        return .finished(leaseRefusal(options: options, error: error))
    case let .success(adopted):
        if let early = await devicePreflight(adopted) {
            return .finished(early)
        }
        return .ready(adopted)
    }
}

enum DeviceCommandPreparation {
    case ready(DeviceCommandOptions)
    case finished(CLIResult)
}

func leaseRefusal(options: DeviceCommandOptions, error: Error) -> CLIResult {
    var refused = deviceCommandResult(options: options, content: "\(error)", isError: true, structured: nil)
    refused.exitCode = 3
    return refused
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

extension DeviceCommandOptions {
    /// Fills the port and device from the presented lease (`--lease` / `AMOO_LEASE`), so a lease id
    /// alone reaches the companion `amoo env up` started. An explicit `--port` / `--device` wins.
    /// A lease for another platform is an error; an unknown or expired lease changes nothing, and
    /// `enforceLease` still refuses a device another session holds.
    func applyingLease(
        store: DeviceClaimStore = DeviceClaimStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result<Self, DeviceLeaseError> {
        guard let leaseID = presentedLease(flag: lease, environment: environment),
              let held = store.claim(id: leaseID)
        else { return .success(self) }
        guard held.amooPlatform == platform else { return .failure(.wrongPlatform(held, requested: platform)) }
        var adopted = self
        if portIsDefault, let port = held.port {
            adopted.port = port
            adopted.portIsDefault = false
        }
        // iOS parsing turns an omitted `--device` into "booted".
        if adopted.deviceID == nil || adopted.deviceID == "booted" {
            adopted.deviceID = held.deviceID
        }
        return .success(adopted)
    }
}
