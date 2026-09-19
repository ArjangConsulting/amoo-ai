import AmooCore
import AndroidDriver
import CompanionProtocol
import ProcessRunner
import SwiftyShell

extension AndroidDeviceSelector {
    /// Reuse the driver's explicit-port launch and boot-completion check for CLI and MCP.
    func bootVirtualDevice(name: String) async throws -> DeviceInfo {
        let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: processRunner))
        let driver = AndroidDriver(
            companion: GRPCCompanionClient.makeFixture(connection: CompanionConnection(host: "127.0.0.1", port: 22088)),
            adb: ADBRunner(context: context),
            emulator: EmulatorRunner(context: context),
            serial: name
        )
        try await driver.boot()
        return try await driver.deviceInfo()
    }
}
