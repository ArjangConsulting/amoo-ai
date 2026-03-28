import Foundation
import MobileTestingCore

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
    private let processRunner: any ProcessRunner

    public init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        self.processRunner = processRunner
    }

    @discardableResult
    public func run(_ arguments: [String]) async throws -> ProcessResult {
        let command = ["adb"] + arguments
        let result = try await processRunner.run(command)
        try ensureSuccessfulExit(result, command: command.joined(separator: " "))
        return result
    }

    // MARK: - Device Lifecycle

    public func startServer() async throws {
        _ = try await run(["start-server"])
    }

    public func killEmulator(serial: String? = nil) async throws {
        var arguments: [String] = serialArgs(serial)
        arguments += ["emu", "kill"]
        _ = try await run(arguments)
    }

    public func listDevices() async throws -> String {
        let result = try await run(["devices", "-l"])
        return result.stdout
    }

    // MARK: - App Management

    public func install(serial: String? = nil, apkPath: String) async throws {
        _ = try await run(serialArgs(serial) + ["install", "-r", apkPath])
    }

    public func launch(serial: String? = nil, appID: String, arguments: [String] = []) async throws {
        let component = try await resolveLaunchableActivity(serial: serial, appID: appID)
        var cmd = serialArgs(serial) + ["shell", "am", "start", "-n", component]
        for arg in arguments {
            cmd += ["--es", "arg", arg]
        }
        _ = try await run(cmd)
    }

    public func terminate(serial: String? = nil, appID: String) async throws {
        _ = try await run(serialArgs(serial) + ["shell", "am", "force-stop", appID])
    }

    public func uninstall(serial: String? = nil, appID: String) async throws {
        _ = try await run(serialArgs(serial) + ["uninstall", appID])
    }

    public func listPackages(serial: String? = nil) async throws -> String {
        let result = try await run(serialArgs(serial) + ["shell", "pm", "list", "packages"])
        return result.stdout
    }

    // MARK: - Capture

    public func screenshot(serial: String? = nil) async throws -> Data {
        let remotePath = "/sdcard/screenshot_tmp.png"
        let localPath = NSTemporaryDirectory() + "screenshot_\(UUID().uuidString).png"
        _ = try await run(serialArgs(serial) + ["shell", "screencap", "-p", remotePath])
        _ = try await run(serialArgs(serial) + ["pull", remotePath, localPath])
        _ = try await run(serialArgs(serial) + ["shell", "rm", remotePath])
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb"] + serialArgs(serial) + ["shell", "screenrecord", outputPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        await ADBRecordingRegistry.shared.register(process, serialKey: serialKey)
    }

    public func stopRecording(serial: String? = nil) async throws {
        let serialKey = serial ?? "__default__"
        if let process = await ADBRecordingRegistry.shared.remove(serialKey: serialKey) {
            process.interrupt()
            process.waitUntilExit()
            return
        }

        _ = try await run(serialArgs(serial) + ["shell", "pkill", "-INT", "screenrecord"])
    }

    // MARK: - Configuration

    public func grantPermission(serial: String? = nil, appID: String, permission: String) async throws {
        _ = try await run(serialArgs(serial) + ["shell", "pm", "grant", appID, permission])
    }

    public func revokePermission(serial: String? = nil, appID: String, permission: String) async throws {
        _ = try await run(serialArgs(serial) + ["shell", "pm", "revoke", appID, permission])
    }

    public func openURL(serial: String? = nil, url: String) async throws {
        _ = try await run(serialArgs(serial) + [
            "shell", "am", "start",
            "-a", "android.intent.action.VIEW",
            "-d", url,
        ])
    }

    // MARK: - Port Forwarding

    public func forwardPort(serial: String? = nil, localPort: Int, remotePort: Int) async throws {
        _ = try await run(serialArgs(serial) + ["forward", "tcp:\(localPort)", "tcp:\(remotePort)"])
    }

    public func removeForward(serial: String? = nil, localPort: Int) async throws {
        _ = try await run(serialArgs(serial) + ["forward", "--remove", "tcp:\(localPort)"])
    }

    // MARK: - Private

    private func serialArgs(_ serial: String?) -> [String] {
        if let serial {
            return ["-s", serial]
        }
        return []
    }

    private func resolveLaunchableActivity(serial: String?, appID: String) async throws -> String {
        do {
            let result = try await run(serialArgs(serial) + ["shell", "cmd", "package", "resolve-activity", "--brief", appID])
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
}

private func ensureSuccessfulExit(_ result: ProcessResult, command: String) throws {
    guard result.exitCode == 0 else {
        throw ProcessRunnerError.nonZeroExit(command: command, exitCode: result.exitCode, stderr: result.stderr)
    }
}

private actor ADBRecordingRegistry {
    static let shared = ADBRecordingRegistry()

    private var processes: [String: Process] = [:]

    func lookup(serialKey: String) -> Process? {
        processes[serialKey]
    }

    func register(_ process: Process, serialKey: String) {
        processes[serialKey] = process
    }

    func remove(serialKey: String) -> Process? {
        processes.removeValue(forKey: serialKey)
    }
}
