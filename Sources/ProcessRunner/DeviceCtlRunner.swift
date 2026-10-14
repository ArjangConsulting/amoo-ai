import AmooCore
import DeviceCtlKit
import Foundation
import SwiftyShell

/// Host-side control of a *physical* iOS device via `xcrun devicectl`.
///
/// This is the physical-device counterpart to ``SimctlRunning``. The two are
/// deliberately separate protocols rather than one shared abstraction: the
/// capability sets genuinely differ (see ``setPermission(device:action:permission:appID:)``),
/// and collapsing them would force every call site to handle "supported here,
/// not there" for operations that are total on one backend.
///
/// All commands request `--json-output -` so parsing is against devicectl's
/// versioned JSON contract rather than its human-readable output, which Apple
/// explicitly documents as unstable across releases.
public protocol DeviceCtlRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) async throws -> ProcessResult

    /// Device discovery
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
    func screenshot(device: String) async throws -> Data
    func startRecording(device: String, outputPath: String) async throws -> Int32
    func stopRecording(pid: Int32) async throws

    // Configuration
    func setLocation(device: String, latitude: Double, longitude: Double) async throws
    func clearLocation(device: String) async throws
    func setAppearance(device: String, appearance: Appearance) async throws
    func openURL(device: String, url: String) async throws
}

public struct DeviceCtlRunner: DeviceCtlRunning {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        try await run(arguments, timeoutSeconds: nil)
    }

    /// Read-only `devicectl` queries have no legitimate reason to run long, but `devicectl` is
    /// known to hang indefinitely — well past any interactive wait — when a previously-paired
    /// device is present but unreachable (e.g. no network path to it). `listDevices()` in
    /// particular runs unconditionally on every session bootstrap (even pure-simulator sessions),
    /// so an unbounded wait there wedges every caller with no build ever starting and no way to
    /// tell a slow query from a truly stuck one.
    @discardableResult
    private func run(_ arguments: [String], timeoutSeconds: TimeInterval?) async throws -> ProcessResult {
        guard !arguments.isEmpty else {
            throw ProcessRunnerError.emptyCommand
        }

        return try await execute(DeviceCtl(context: context).custom(arguments), timeoutSeconds: timeoutSeconds)
    }

    @discardableResult
    private func execute(_ devicectl: DeviceCtl, timeoutSeconds: TimeInterval? = nil) async throws -> ProcessResult {
        var command = devicectl.command()
        if let timeoutSeconds {
            command = command.timeout(.seconds(timeoutSeconds))
        }
        do {
            return try await command.run(in: context).processResult
        } catch let error as ShellError {
            throw processRunnerError(
                error,
                command: ([command.executableName] + command.arguments).joined(separator: " ")
            )
        }
    }

    // MARK: - Device Discovery

    public func listDevices() async throws -> String {
        let result = try await execute(DeviceCtl(context: context).listDevices().jsonOutput(), timeoutSeconds: 20)
        return result.stdout
    }

    // MARK: - App Management

    public func install(device: String, appPath: String) async throws {
        try await execute(DeviceCtl(context: context).install(appPath: appPath, device: device))
    }

    public func launch(
        device: String,
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        // `--terminate-existing` matches simctl's behaviour of replacing a running instance rather than
        // failing or attaching to it. Everything after the bundle identifier is forwarded to the app.
        try await execute(DeviceCtl(context: context).launch(
            bundleID: appID, device: device, terminateExisting: true, environment: environment, arguments: arguments
        ))
    }

    /// Terminates the app by resolving its bundle ID to a running PID, then signalling it.
    ///
    /// Unlike `simctl terminate`, devicectl has no bundle-ID-based terminate — it only
    /// signals a PID, so the lookup is required.
    public func terminate(device: String, appID: String) async throws {
        guard let pid = try await runningProcessID(device: device, appID: appID) else {
            // Nothing running for this bundle ID. `simctl terminate` errors here, but
            // treating "already not running" as success makes teardown idempotent.
            return
        }

        try await execute(DeviceCtl(context: context).signal("SIGKILL", pid: pid, device: device))
    }

    public func uninstall(device: String, appID: String) async throws {
        try await execute(DeviceCtl(context: context).uninstall(bundleID: appID, device: device))
    }

    public func listApps(device: String) async throws -> String {
        let result = try await execute(
            DeviceCtl(context: context).apps(device: device).jsonOutput(),
            timeoutSeconds: 20
        )
        return result.stdout
    }

    // MARK: - Capture

    public func screenshot(device: String) async throws -> Data {
        // devicectl only writes PNG, and only to a path — there is no stdout mode.
        let tmpPath = NSTemporaryDirectory() + "screenshot_\(UUID().uuidString).png"
        try await execute(DeviceCtl(context: context).screenshot(device: device, destination: tmpPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        try? FileManager.default.removeItem(atPath: tmpPath)
        return data
    }

    /// Starts an open-ended screen recording, returning the PID to stop it with.
    ///
    /// `devicectl device capture screen-record` records until interrupted, exactly
    /// like `simctl io recordVideo`, so the spawn-then-SIGINT lifecycle matches.
    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        let command = DeviceCtl(context: context).screenRecord(device: device, destination: outputPath).command()
        let process = try await command.spawn(in: context, teardown: .interruptThenTerminate)
        await DeviceCtlRecordingRegistry.shared.register(process)
        return process.processIdentifier
    }

    public func stopRecording(pid: Int32) async throws {
        if let process = await DeviceCtlRecordingRegistry.shared.remove(pid: pid) {
            // SIGINT is what finalizes the .mp4 — SIGKILL would leave it truncated.
            try await process.interrupt()
            _ = await process.waitForExit()
            return
        }

        _ = try await SystemProcessRunner(context: context).run(["kill", "-INT", String(pid)])
    }

    // MARK: - Configuration

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        try await execute(DeviceCtl(context: context).simulateLocation(
            latitude: latitude,
            longitude: longitude,
            device: device
        ))
    }

    public func clearLocation(device: String) async throws {
        try await execute(DeviceCtl(context: context).clearSimulatedLocation(device: device))
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        try await execute(DeviceCtl(context: context).appearance(appearance == .dark ? .dark : .light, device: device))
    }

    /// Opens a URL by launching the app registered for it with a payload URL.
    ///
    /// devicectl has no standalone `openurl`; `--payload-url` on a launch is the
    /// documented equivalent.
    public func openURL(device: String, url: String) async throws {
        try await execute(DeviceCtl(context: context).launch(
            bundleID: Self.safariBundleID,
            device: device,
            payloadURL: url
        ))
    }

    /// Bundle identifier used to service `openURL`, mirroring how a tapped link resolves.
    private static let safariBundleID = "com.apple.mobilesafari"

    // MARK: - Helpers

    /// Resolves a bundle identifier to a running process ID, or `nil` when not running.
    private func runningProcessID(device: String, appID: String) async throws -> Int32? {
        let result = try await execute(
            DeviceCtl(context: context).processes(device: device).jsonOutput(),
            timeoutSeconds: 20
        )
        return Self.parseProcessID(json: result.stdout, appID: appID)
    }

    /// Matches a bundle identifier against devicectl's process list.
    ///
    /// devicectl reports processes by executable path rather than bundle ID, so the
    /// match is on the `.app/<Name>` path component that the bundle ID's app carries.
    static func parseProcessID(json: String, appID: String) -> Int32? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let processes = result["runningProcesses"] as? [[String: Any]]
        else { return nil }

        for process in processes {
            guard let pid = process["processIdentifier"] as? Int else { continue }
            // `executable` looks like file:///.../Foo.app/Foo — the bundle ID's last
            // component is conventionally the executable name.
            let executable = process["executable"] as? String ?? ""
            if executable.contains("/\(appID)/") || executable.contains(".app") {
                if matchesBundle(executable: executable, appID: appID) {
                    return Int32(pid)
                }
            }
        }
        return nil
    }

    private static func matchesBundle(executable: String, appID: String) -> Bool {
        // Compare against the final bundle-ID segment, which matches the .app name for
        // the overwhelming majority of apps (com.example.Foo -> Foo.app).
        guard let lastSegment = appID.split(separator: ".").last else { return false }
        return executable.contains("/\(lastSegment).app/")
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

private actor DeviceCtlRecordingRegistry {
    static let shared = DeviceCtlRecordingRegistry()

    private var processes: [Int32: any SpawnedProcess] = [:]

    func register(_ process: any SpawnedProcess) {
        processes[process.processIdentifier] = process
    }

    func remove(pid: Int32) -> (any SpawnedProcess)? {
        processes.removeValue(forKey: pid)
    }
}
