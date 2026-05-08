import Foundation
import GradleKit
import MobileTestingCore
import SwiftyShell

public protocol ADBRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) async throws -> ProcessResult

    // Device lifecycle
    func startServer() async throws
    func killEmulator(serial: String?) async throws
    func listDevices() async throws -> String

    // App management
    func install(serial: String?, apkPath: String) async throws
    func launch(serial: String?, appID: String, arguments: [String]) async throws
    func terminate(serial: String?, appID: String) async throws
    func uninstall(serial: String?, appID: String) async throws
    func listPackages(serial: String?) async throws -> String

    // Capture
    func screenshot(serial: String?) async throws -> Data
    func startRecording(serial: String?, outputPath: String) async throws
    func stopRecording(serial: String?) async throws

    // Configuration
    func grantPermission(serial: String?, appID: String, permission: String) async throws
    func revokePermission(serial: String?, appID: String, permission: String) async throws
    func openURL(serial: String?, url: String) async throws

    // Port forwarding
    func forwardPort(serial: String?, localPort: Int, remotePort: Int) async throws
    func removeForward(serial: String?, localPort: Int) async throws
}

public struct ADBRunner: ADBRunning {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        do {
            return try await Adb(context: context)
                .rawArguments(arguments)
                .run()
                .processResult
        } catch let error as ShellError {
            throw processRunnerError(error, command: (["adb"] + arguments).joined(separator: " "))
        }
    }

    // MARK: - Device Lifecycle

    public func startServer() async throws {
        _ = try await run(Adb(context: context).startServer())
    }

    public func killEmulator(serial: String? = nil) async throws {
        _ = try await run(adb(serial: serial).emuKill())
    }

    public func listDevices() async throws -> String {
        let result = try await run(Adb(context: context).devices(long: true))
        return result.stdout
    }

    // MARK: - App Management

    public func install(serial: String? = nil, apkPath: String) async throws {
        _ = try await run(adb(serial: serial).install(apk: apkPath, replace: true))
    }

    public func launch(serial: String? = nil, appID: String, arguments: [String] = []) async throws {
        let component = try await resolveLaunchableActivity(serial: serial, appID: appID)
        _ = try await run(
            adb(serial: serial).amStartActivity(component: component, arguments: arguments)
        )
    }

    public func terminate(serial: String? = nil, appID: String) async throws {
        _ = try await run(adb(serial: serial).amForceStop(package: appID))
    }

    public func uninstall(serial: String? = nil, appID: String) async throws {
        _ = try await run(adb(serial: serial).uninstall(package: appID))
    }

    public func listPackages(serial: String? = nil) async throws -> String {
        let result = try await run(adb(serial: serial).pmListPackages())
        return result.stdout
    }

    // MARK: - Capture

    public func screenshot(serial: String? = nil) async throws -> Data {
        let remotePath = "/sdcard/screenshot_tmp.png"
        let localPath = NSTemporaryDirectory() + "screenshot_\(UUID().uuidString).png"
        _ = try await run(adb(serial: serial).screencap(remotePath: remotePath))
        _ = try await run(adb(serial: serial).pull(remote: remotePath, local: localPath))
        _ = try await run(adb(serial: serial).shell("rm \(remotePath)"))
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
        try? FileManager.default.removeItem(atPath: localPath)
        return data
    }

    public func startRecording(serial: String? = nil, outputPath: String) async throws {
        let serialKey = serial ?? "__default__"
        guard await ADBRecordingRegistry.shared.lookup(serialKey: serialKey) == nil else {
            throw MobileTestingError.commandFailed(
                command: "adb screenrecord",
                output: "A recording is already active for \(serial ?? "default device")."
            )
        }

        let process = try await adb(serial: serial)
            .screenrecord(remotePath: outputPath)
            .spawn(teardown: .interruptThenTerminate)
        await ADBRecordingRegistry.shared.register(process, serialKey: serialKey)
    }

    public func stopRecording(serial: String? = nil) async throws {
        let serialKey = serial ?? "__default__"
        if let process = await ADBRecordingRegistry.shared.remove(serialKey: serialKey) {
            try await process.interrupt()
            _ = await process.waitForExit()
            return
        }

        _ = try await run(adb(serial: serial).shellPkill(process: "screenrecord"))
    }

    // MARK: - Configuration

    public func grantPermission(serial: String? = nil, appID: String, permission: String) async throws {
        _ = try await run(adb(serial: serial).pmGrantPermission(package: appID, permission: permission))
    }

    public func revokePermission(serial: String? = nil, appID: String, permission: String)
        async throws {
        _ = try await run(
            adb(serial: serial).pmRevokePermission(package: appID, permission: permission)
        )
    }

    public func openURL(serial: String? = nil, url: String) async throws {
        _ = try await run(adb(serial: serial).amStartViewURL(url))
    }

    // MARK: - Port Forwarding

    public func forwardPort(serial: String? = nil, localPort: Int, remotePort: Int) async throws {
        _ = try await run(adb(serial: serial).forwardTCP(localPort: localPort, remotePort: remotePort))
    }

    public func removeForward(serial: String? = nil, localPort: Int) async throws {
        _ = try await run(adb(serial: serial).removeForwardTCP(localPort: localPort))
    }

    // MARK: - Private

    private func adb(serial: String?) -> Adb {
        Adb(context: context).serial(serial)
    }

    private func resolveLaunchableActivity(serial: String?, appID: String) async throws -> String {
        do {
            let result = try await run(adb(serial: serial).resolveLaunchableActivity(package: appID))
            let lines = result.stdout
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            if let component = lines.last(where: { $0.contains("/") }) {
                return component
            }
        } catch {
            // Fall through to the generic launcher below.
        }

        return "\(appID)/.MainActivity"
    }

    private func run(_ command: Adb) async throws -> ProcessResult {
        do {
            return try await command.run().processResult
        } catch let error as ShellError {
            throw processRunnerError(error, command: command.command().displayString())
        }
    }
}

private func processRunnerError(_ error: ShellError, command: String) -> Error {
    if case let .exitFailure(_, output) = error {
        return ProcessRunnerError.nonZeroExit(
            command: command, exitCode: output.exitCode, stderr: output.stderr
        )
    }
    return error
}

private actor ADBRecordingRegistry {
    static let shared = ADBRecordingRegistry()

    private var processes: [String: any SpawnedProcess] = [:]

    func lookup(serialKey: String) -> (any SpawnedProcess)? {
        processes[serialKey]
    }

    func register(_ process: any SpawnedProcess, serialKey: String) {
        processes[serialKey] = process
    }

    func remove(serialKey: String) -> (any SpawnedProcess)? {
        processes.removeValue(forKey: serialKey)
    }
}
