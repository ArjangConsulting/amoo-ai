import AmooCore
import Foundation
import ShipItKit
import SwiftyShell

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

public struct SimctlRunner: SimctlRunning {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
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
        _ = try await run(.shutdown([device]))
    }

    public func listDevices() async throws -> String {
        let result = try await run(.list(.devices, json: true, searchTerm: "available"))
        return result.stdout
    }

    // MARK: - App Management

    public func install(device: String, appPath: String) async throws {
        _ = try await run(.install(device, appAt: appPath))
    }

    public func launch(
        device: String,
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        // `simctl` reads `SIMCTL_CHILD_<KEY>` from its own environment and
        // re-exports them as `<KEY>` to the launched app. This is Apple's
        // documented way to pass environment variables through `simctl launch`.
        let childEnv = Dictionary(uniqueKeysWithValues: environment.map {
            ("SIMCTL_CHILD_\($0.key)", $0.value)
        })
        _ = try await run(
            .launch(device, bundleIdentifier: appID),
            trailingArguments: arguments,
            environment: childEnv
        )
    }

    public func terminate(device: String, appID: String) async throws {
        _ = try await run(.terminate(device, bundleIdentifier: appID))
    }

    public func uninstall(device: String, appID: String) async throws {
        _ = try await run(.uninstall(device, bundleIdentifier: appID))
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

    private func run(
        _ command: SimctlCommand,
        trailingArguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> ProcessResult {
        do {
            var builder = Simctl(context: context)
                .command(command)
                .args(trailingArguments)
            if !environment.isEmpty {
                builder = builder.env(environment)
            }
            return try await builder.run().processResult
        } catch let error as ShellError {
            throw processRunnerError(
                error,
                command: (["xcrun", "simctl"] + command.arguments + trailingArguments).joined(
                    separator: " "
                )
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
