import Foundation
import MobileTestingCore

public protocol SimctlRunning: Sendable {
    @discardableResult
    func run(_ arguments: [String]) async throws -> ProcessResult

    // Device lifecycle
    func bootStatus(device: String) async throws
    func shutdown(device: String) async throws
    func listDevices() async throws -> String

    // App management
    func install(device: String, appPath: String) async throws
    func launch(device: String, appID: String, arguments: [String]) async throws
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

public struct SimctlRunner: SimctlRunning {
    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        let command = ["xcrun", "simctl"] + arguments
        let result = try await processRunner.run(command)
        try ensureSuccessfulExit(result, command: command.joined(separator: " "))
        return result
    }

    // MARK: - Device Lifecycle

    public func bootStatus(device: String = "booted") async throws {
        _ = try await run(["bootstatus", device])
    }

    public func shutdown(device: String = "booted") async throws {
        _ = try await run(["shutdown", device])
    }

    public func listDevices() async throws -> String {
        let result = try await run(["list", "devices", "available", "-j"])
        return result.stdout
    }

    // MARK: - App Management

    public func install(device: String, appPath: String) async throws {
        _ = try await run(["install", device, appPath])
    }

    public func launch(device: String, appID: String, arguments: [String] = []) async throws {
        _ = try await run(["launch", device, appID] + arguments)
    }

    public func terminate(device: String, appID: String) async throws {
        _ = try await run(["terminate", device, appID])
    }

    public func uninstall(device: String, appID: String) async throws {
        _ = try await run(["uninstall", device, appID])
    }

    public func listApps(device: String) async throws -> String {
        let result = try await run(["listapps", device])
        return result.stdout
    }

    // MARK: - Capture

    public func screenshot(device: String, format: ImageFormat = .png) async throws -> Data {
        let tmpPath = NSTemporaryDirectory() + "screenshot_\(UUID().uuidString).\(format.rawValue)"
        _ = try await run(["io", device, "screenshot", "--type=\(format.rawValue)", tmpPath])
        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        try? FileManager.default.removeItem(atPath: tmpPath)
        return data
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264", "--force", outputPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        await SimctlRecordingRegistry.shared.register(process)
        return process.processIdentifier
    }

    public func stopRecording(pid: Int32) async throws {
        if let process = await SimctlRecordingRegistry.shared.remove(pid: pid) {
            process.interrupt()
            process.waitUntilExit()
            return
        }

        _ = try await processRunner.run(["kill", "-INT", String(pid)])
    }

    // MARK: - Configuration

    public func setPermission(device: String, action: String, permission: String, appID: String) async throws {
        _ = try await run(["privacy", device, action, permission, appID])
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        _ = try await run(["location", device, "set", "\(latitude),\(longitude)"])
    }

    public func clearLocation(device: String) async throws {
        _ = try await run(["location", device, "clear"])
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        _ = try await run(["ui", device, "appearance", appearance.rawValue])
    }

    public func openURL(device: String, url: String) async throws {
        _ = try await run(["openurl", device, url])
    }

    // MARK: - App Inspection

    public func listInstalledAppIDs(device: String) async throws -> [String] {
        let result = try await run(["listapps", device])
        guard let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else { return [] }
        return Array(dict.keys)
    }
}

private func ensureSuccessfulExit(_ result: ProcessResult, command: String) throws {
    guard result.exitCode == 0 else {
        throw ProcessRunnerError.nonZeroExit(command: command, exitCode: result.exitCode, stderr: result.stderr)
    }
}

private actor SimctlRecordingRegistry {
    static let shared = SimctlRecordingRegistry()

    private var processes: [Int32: Process] = [:]

    func register(_ process: Process) {
        processes[process.processIdentifier] = process
    }

    func remove(pid: Int32) -> Process? {
        processes.removeValue(forKey: pid)
    }
}
