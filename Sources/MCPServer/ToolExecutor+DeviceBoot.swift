import AmooCore
import AmooLogging
import MCP

extension DriverToolExecutor {
    func executeDeviceBoot(driver: any PlatformDriver, arguments: [String: String]) async throws -> ToolResult {
        let operation = StartupOperation()
        await StartupProgressStore.shared.add(operation)
        let logger = AmooLogger.forType(Self.self)
        return try await StartupProgress.$startup.withValue(operation) {
            logger.info("Device boot requested", context: "stage=resolve")
            await StartupProgress.report("Resolving device for boot")
            do {
                let info = try await bootAndInspectDevice(driver: driver, arguments: arguments)
                guard info.state == .booted else {
                    throw AmooError.commandFailed(
                        command: "device_boot",
                        output: "device state is \(info.state.rawValue)"
                    )
                }
                logger.info("Device boot verified", context: "stage=verified")
                await StartupProgress.report("Device boot verified")
                await operation.finish(success: true)
                return .success(
                    "Device booted and verified: \(info.name)",
                    structuredContent: .object(["verified": .bool(true), "device_id": .string(info.id)])
                )
            } catch {
                logger.error("Device boot failed", error: error, context: "stage=boot_or_verify")
                await StartupProgress.report("Device boot failed; inspect device state before retrying")
                await operation.finish(success: false)
                throw error
            }
        }
    }

    private func bootAndInspectDevice(
        driver: any PlatformDriver,
        arguments: [String: String]
    ) async throws -> DeviceInfo {
        if let hint = arguments["device_hint"], !hint.isEmpty, let manager = sessionManager {
            let platform = arguments["platform"].flatMap { Platform(rawValue: $0.lowercased()) }
                ?? defaultPlatform ?? .ios
            return try await manager.bootDevice(hint: hint, platform: platform)
        }
        await StartupProgress.report("Booting bound device")
        try await driver.boot()
        await StartupProgress.report("Verifying device boot state")
        return try await driver.deviceInfo()
    }
}
