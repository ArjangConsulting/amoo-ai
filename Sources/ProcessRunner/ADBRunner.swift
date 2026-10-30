import AdbKit
import AmooCore
import Foundation
import GradleKit
import MobileCore
import MobileDevices
import SwiftyShell

public protocol ADBRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) async throws -> ProcessResult
    /// Execute a command with an explicit deadline (seconds).
    func run(_ arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult

    // Device lifecycle
    func startServer() async throws
    func killEmulator(serial: String?) async throws
    func listDevices() async throws -> String

    // App management
    func install(serial: String?, apkPath: String) async throws
    func launch(serial: String?, appID: String, arguments: [String]) async throws
    /// Launches with `environment` as `--es KEY VALUE` Intent extras (Android has no process
    /// environment for apps) after force-stopping the app, so a fresh `onCreate` sees them.
    func launch(serial: String?, appID: String, arguments: [String], environment: [String: String]) async throws
    func launchResetting(serial: String?, appID: String) async throws
    func terminate(serial: String?, appID: String) async throws
    func uninstall(serial: String?, appID: String) async throws
    func clearAppData(serial: String?, appID: String) async throws
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

public extension ADBRunning {
    func run(_ arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
        try await run(arguments)
    }

    func launch(serial: String?, appID: String, arguments: [String], environment _: [String: String]) async throws {
        try await launch(serial: serial, appID: appID, arguments: arguments)
    }
}

public struct ADBRunner: ADBRunning {
    /// Deadline for the raw `run(_:)` passthrough; the typed operations use MobileDevices' own deadlines.
    private static let readTimeoutSeconds: TimeInterval = 20

    private let context: ShellContext
    private let emulatorDiscovery: AndroidEmulatorDiscovery
    private let shutdownTimeout: TimeInterval

    public init(
        context: ShellContext = .init(),
        emulatorDiscoveryDirectories: [URL]? = nil,
        shutdownTimeout: TimeInterval = 30
    ) {
        self.context = context
        emulatorDiscovery = AndroidEmulatorDiscovery(context: context, directories: emulatorDiscoveryDirectories)
        self.shutdownTimeout = shutdownTimeout
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        try await run(arguments, timeoutSeconds: Self.readTimeoutSeconds)
    }

    public func run(_ arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
        do {
            return try await Adb(context: context)
                .rawArguments(arguments)
                .timeout(.seconds(timeoutSeconds))
                .run()
                .processResult
        } catch let error as ShellError {
            throw processRunnerError(error, command: (["adb"] + arguments).joined(separator: " "))
        }
    }

    // MARK: - Device Lifecycle

    public func startServer() async throws {
        try await translatingMobileKitErrors {
            try await devices.startServer()
        }
    }

    public func killEmulator(serial: String? = nil) async throws {
        try await onDevice(serial) { serial in
            let registration = try await emulatorDiscovery.runningEmulators().first { $0.serial == serial }
            do {
                _ = try await run(["-s", serial, "emu", "kill"], timeoutSeconds: 3)
            } catch {
                guard let registration else { throw error }
                try await terminateRegisteredEmulator(registration)
            }
            let deadline = ContinuousClock.now + .seconds(shutdownTimeout)
            let gracefulDeadline = ContinuousClock.now + .seconds(10)
            var terminationRequested = false
            repeat {
                try Task.checkCancellation()
                let processRunning: Bool = if let registration {
                    try await emulatorDiscovery.isRunning(registration)
                } else {
                    false
                }
                let connected = try await run(["devices", "-l"], timeoutSeconds: 2).stdout
                    .split(whereSeparator: \.isNewline)
                    .contains { $0.split(whereSeparator: \.isWhitespace).first == Substring(serial) }
                if !processRunning, !connected {
                    return
                }
                if processRunning, !terminationRequested, ContinuousClock.now >= gracefulDeadline, let registration {
                    try await terminateRegisteredEmulator(registration)
                    terminationRequested = true
                }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            throw AmooError.commandFailed(
                command: "device_shutdown",
                output: "Emulator \(serial) has not exited; shutdown is unverified."
                    + " Do not start another instance of its AVD."
            )
        }
    }

    public func listDevices() async throws -> String {
        try await translatingMobileKitErrors {
            try await devices.devicesOutput()
        }
    }

    private func terminateRegisteredEmulator(_ registration: AndroidEmulatorRegistration) async throws {
        guard try await emulatorDiscovery.isRunning(registration) else { return }
        _ = try await Command("kill").args(["-TERM", String(registration.pid)])
            .timeout(.seconds(2)).run(in: context)
    }

    // MARK: - App Management

    public func install(serial: String? = nil, apkPath: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.install(apkAt: apkPath, on: serial)
        }
    }

    /// Launches without `--activity-clear-top` and without a force-stop, as this overload always did.
    public func launch(serial: String? = nil, appID: String, arguments: [String] = []) async throws {
        try await launch(
            serial: serial,
            appID: appID,
            options: AndroidLaunchOptions(arguments: arguments, clearTop: false, forceStopFirst: false)
        )
    }

    /// Launches with `--activity-clear-top`; a non-empty `environment` force-stops the app first.
    public func launch(
        serial: String?,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await launch(
            serial: serial,
            appID: appID,
            options: AndroidLaunchOptions(arguments: arguments, environment: environment)
        )
    }

    public func launchResetting(serial: String? = nil, appID: String) async throws {
        try await launch(serial: serial, appID: appID, options: AndroidLaunchOptions())
    }

    public func terminate(serial: String? = nil, appID: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.terminate(package: appID, on: serial)
        }
    }

    public func uninstall(serial: String? = nil, appID: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.uninstall(package: appID, from: serial)
        }
    }

    public func clearAppData(serial: String? = nil, appID: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.clearData(package: appID, on: serial)
        }
    }

    public func listPackages(serial: String? = nil) async throws -> String {
        try await onDevice(serial) { serial in
            try await devices.installedPackagesOutput(on: serial)
        }
    }

    // MARK: - Capture

    public func screenshot(serial: String? = nil) async throws -> Data {
        try await onDevice(serial) { serial in
            try await devices.screenshot(on: serial)
        }
    }

    /// Starts `screenrecord`, writing to `outputPath` on the device.
    ///
    /// A second recording on the same device fails with ``AmooError/commandFailed(command:output:)``.
    public func startRecording(serial: String? = nil, outputPath: String) async throws {
        do {
            try await onDevice(serial) { serial in
                try await devices.startRecording(on: serial, remotePath: outputPath)
            }
        } catch let MobileKitError.invalidRequest(message) {
            throw AmooError.commandFailed(command: "adb screenrecord", output: message)
        }
    }

    public func stopRecording(serial: String? = nil) async throws {
        try await onDevice(serial) { serial in
            try await devices.stopRecording(on: serial)
        }
    }

    // MARK: - Configuration

    public func grantPermission(serial: String? = nil, appID: String, permission: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.grantPermission(permission, to: appID, on: serial)
        }
    }

    public func revokePermission(serial: String? = nil, appID: String, permission: String)
        async throws {
        try await onDevice(serial) { serial in
            try await devices.revokePermission(permission, from: appID, on: serial)
        }
    }

    public func openURL(serial: String? = nil, url: String) async throws {
        try await onDevice(serial) { serial in
            try await devices.openURL(url, on: serial)
        }
    }

    // MARK: - Port Forwarding

    public func forwardPort(serial: String? = nil, localPort: Int, remotePort: Int) async throws {
        try await onDevice(serial) { serial in
            try await devices.forwardPort(local: localPort, remote: remotePort, on: serial)
        }
    }

    public func removeForward(serial: String? = nil, localPort: Int) async throws {
        try await onDevice(serial) { serial in
            try await devices.removeForward(local: localPort, on: serial)
        }
    }

    // MARK: - Private

    private var devices: AndroidDeviceManager {
        AndroidDeviceManager(shell: context)
    }

    private func launch(serial: String?, appID: String, options: AndroidLaunchOptions) async throws {
        do {
            try await onDevice(serial) { serial in
                try await devices.launch(package: appID, on: serial, options: options)
            }
        } catch let MobileKitError.notFound(message) {
            throw ProcessRunnerError.nonZeroExit(command: "resolve-activity \(appID)", exitCode: 1, stderr: message)
        }
    }

    /// Runs `body` on `serial`, or on the only attached device when it is nil (the way `adb` without
    /// `-s` picks one), rethrowing MobileDevices failures as ``ProcessRunnerError``.
    private func onDevice<Result>(
        _ serial: String?,
        _ body: (String) async throws -> Result
    ) async throws -> Result {
        try await translatingMobileKitErrors {
            try await body(devices.resolveSerial(serial))
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
