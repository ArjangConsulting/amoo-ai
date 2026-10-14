import AmooCore
import Foundation
import SwiftyShell
#if os(macOS)
import MobileDevices
import XcrunKit
#endif

public protocol SimctlRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) async throws -> ProcessResult

    // Device lifecycle
    func bootStatus(device: String) async throws
    func shutdown(device: String) async throws
    func listDevices() async throws -> String

    // App management
    func install(device: String, appPath: String) async throws
    func launch(
        device: String,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws
    func terminate(device: String, appID: String) async throws
    func uninstall(device: String, appID: String) async throws
    func listApps(device: String) async throws -> String

    // Capture
    func screenshot(device: String, format: ImageFormat) async throws -> Data
    func startRecording(device: String, outputPath: String) async throws -> Int32
    func stopRecording(pid: Int32) async throws

    // Configuration
    func setPermission(device: String, action: String, permission: String, appID: String) async throws
    func setLocation(device: String, latitude: Double, longitude: Double) async throws
    func clearLocation(device: String) async throws
    func setAppearance(device: String, appearance: Appearance) async throws
    func openURL(device: String, url: String) async throws

    /// App inspection
    func listInstalledAppIDs(device: String) async throws -> [String]
}

#if os(macOS)
public struct SimctlRunner: SimctlRunning {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    private var simulators: SimulatorManager {
        SimulatorManager(shell: context)
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        guard let subcommand = arguments.first else {
            throw ProcessRunnerError.emptyCommand
        }

        do {
            return try await Simctl(context: context)
                .custom(subcommand, arguments: Array(arguments.dropFirst()))
                .run()
                .processResult
        } catch let error as ShellError {
            throw processRunnerError(
                error, command: (["xcrun", "simctl"] + arguments).joined(separator: " ")
            )
        }
    }

    // MARK: - Device Lifecycle

    public func bootStatus(device: String = "booted") async throws {
        _ = try await run(.bootStatus(device))
    }

    public func shutdown(device: String = "booted") async throws {
        try await translatingMobileKitErrors { try await simulators.shutdown(device) }
    }

    public func listDevices() async throws -> String {
        let result = try await run(.list(.devices, json: true, searchTerm: "available"))
        return result.stdout
    }

    // MARK: - App Management

    public func install(device: String, appPath: String) async throws {
        try await translatingMobileKitErrors { try await simulators.install(appAt: appPath, on: device) }
    }

    public func launch(
        device: String,
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        // `SimulatorManager` re-exports `environment` as `SIMCTL_CHILD_<KEY>` and passes
        // `--terminate-running-process`, so launching starts a fresh process as it does on a
        // physical device (devicectl's `--terminate-existing`) instead of re-activating a running
        // app that keeps its old state.
        _ = try await translatingMobileKitErrors {
            try await simulators.launch(
                bundleID: appID, on: device, arguments: arguments, environment: environment
            )
        }
    }

    public func terminate(device: String, appID: String) async throws {
        try await translatingMobileKitErrors { try await simulators.terminate(bundleID: appID, on: device) }
    }

    public func uninstall(device: String, appID: String) async throws {
        try await translatingMobileKitErrors { try await simulators.uninstall(bundleID: appID, from: device) }
    }

    public func listApps(device: String) async throws -> String {
        let result = try await run(.custom("listapps", arguments: [device]))
        return result.stdout
    }

    // MARK: - Capture

    public func screenshot(device: String, format: ImageFormat = .png) async throws -> Data {
        let tmpPath = NSTemporaryDirectory() + "screenshot_\(UUID().uuidString).\(format.rawValue)"
        _ = try await run(
            .io(device, command: "screenshot", arguments: ["--type=\(format.rawValue)", tmpPath])
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        try? FileManager.default.removeItem(atPath: tmpPath)
        return data
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        let process = try await Simctl(context: context)
            .command(
                .io(device, command: "recordVideo", arguments: ["--codec=h264", "--force", outputPath])
            )
            .spawn(teardown: .interruptThenTerminate)
        await SimctlRecordingRegistry.shared.register(process)
        return process.processIdentifier
    }

    public func stopRecording(pid: Int32) async throws {
        if let process = await SimctlRecordingRegistry.shared.remove(pid: pid) {
            try await process.interrupt()
            _ = await process.waitForExit()
            return
        }

        _ = try await SystemProcessRunner(context: context).run(["kill", "-INT", String(pid)])
    }

    // MARK: - Configuration

    public func setPermission(device: String, action: String, permission: String, appID: String)
        async throws {
        _ = try await run(
            .privacy(device, action: action, service: permission, bundleIdentifier: appID)
        )
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        _ = try await run(.location(device, action: "set", arguments: ["\(latitude),\(longitude)"]))
    }

    public func clearLocation(device: String) async throws {
        _ = try await run(.location(device, action: "clear"))
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        _ = try await run(.ui(device, arguments: ["appearance", appearance.rawValue]))
    }

    public func openURL(device: String, url: String) async throws {
        _ = try await run(.openURL(device, url))
    }

    // MARK: - App Inspection

    public func listInstalledAppIDs(device: String) async throws -> [String] {
        let result = try await run(.custom("listapps", arguments: [device]))
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return [] }
        return Array(dict.keys)
    }

    private func run(_ command: SimctlCommand) async throws -> ProcessResult {
        do {
            return try await Simctl(context: context).command(command).run().processResult
        } catch let error as ShellError {
            throw processRunnerError(
                error, command: (["xcrun", "simctl"] + command.arguments).joined(separator: " ")
            )
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

private actor SimctlRecordingRegistry {
    static let shared = SimctlRecordingRegistry()

    private var processes: [Int32: any SpawnedProcess] = [:]

    func register(_ process: any SpawnedProcess) {
        processes[process.processIdentifier] = process
    }

    func remove(pid: Int32) -> (any SpawnedProcess)? {
        processes.removeValue(forKey: pid)
    }
}

#else

/// `xcrun simctl` only exists on macOS (it ships with Xcode), and ShipItKit's `Simctl` command
/// builder is itself `#if os(macOS)`-gated. This stub keeps `SimctlRunner` linkable on Linux so
/// the rest of the CLI (which references the type unconditionally) still compiles there — every
/// call fails at runtime with a clear error instead of the binary failing to build at all, the
/// same pattern `preflight` already uses for other macOS-only tooling.
public struct SimctlRunner: SimctlRunning {
    public init(context: ShellContext = .init()) {}

    private func unsupported() -> Error {
        ProcessRunnerError.nonZeroExit(
            command: "xcrun simctl",
            exitCode: 127,
            stderr: "simctl is only available on macOS."
        )
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        throw unsupported()
    }

    public func bootStatus(device: String = "booted") async throws {
        throw unsupported()
    }

    public func shutdown(device: String = "booted") async throws {
        throw unsupported()
    }

    public func listDevices() async throws -> String {
        throw unsupported()
    }

    public func install(device: String, appPath: String) async throws {
        throw unsupported()
    }

    public func launch(
        device: String,
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        throw unsupported()
    }

    public func terminate(device: String, appID: String) async throws {
        throw unsupported()
    }

    public func uninstall(device: String, appID: String) async throws {
        throw unsupported()
    }

    public func listApps(device: String) async throws -> String {
        throw unsupported()
    }

    public func screenshot(device: String, format: ImageFormat = .png) async throws -> Data {
        throw unsupported()
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        throw unsupported()
    }

    public func stopRecording(pid: Int32) async throws {
        throw unsupported()
    }

    public func setPermission(device: String, action: String, permission: String, appID: String)
        async throws {
        throw unsupported()
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        throw unsupported()
    }

    public func clearLocation(device: String) async throws {
        throw unsupported()
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        throw unsupported()
    }

    public func openURL(device: String, url: String) async throws {
        throw unsupported()
    }

    public func listInstalledAppIDs(device: String) async throws -> [String] {
        throw unsupported()
    }
}

#endif
