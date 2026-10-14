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

    /// Stays on the raw wrapper: the protocol returns simctl's JSON verbatim for the CLI's own
    /// parsers (`DeviceSelector`, `CompanionManager`, preflight), and `SimulatorManager.list`
    /// returns a lossy `[Simulator]` model, so delegating would change what callers receive.
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
        try await translatingMobileKitErrors { try await simulators.listApps(on: device) }
    }

    // MARK: - Capture

    public func screenshot(device: String, format: ImageFormat = .png) async throws -> Data {
        try await translatingMobileKitErrors {
            try await simulators.screenshot(device, format: format.simulatorFormat)
        }
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        try await translatingMobileKitErrors {
            try await simulators.startRecording(on: device, to: outputPath)
        }
    }

    public func stopRecording(pid: Int32) async throws {
        try await translatingMobileKitErrors { try await simulators.stopRecording(pid: pid) }
    }

    // MARK: - Configuration

    public func setPermission(device: String, action: String, permission: String, appID: String)
        async throws {
        guard let privacyAction = SimulatorPrivacyAction(rawValue: action) else {
            let supported = SimulatorPrivacyAction.allCases.map(\.rawValue).joined(separator: ", ")
            throw ProcessRunnerError.nonZeroExit(
                command: "xcrun simctl privacy \(device) \(action) \(permission) \(appID)",
                exitCode: 64,
                stderr: "Unknown permission action '\(action)'; expected one of: \(supported)."
            )
        }
        try await translatingMobileKitErrors {
            try await simulators.privacy(privacyAction, service: permission, bundleID: appID, on: device)
        }
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        try await translatingMobileKitErrors {
            try await simulators.setLocation(latitude: latitude, longitude: longitude, on: device)
        }
    }

    public func clearLocation(device: String) async throws {
        try await translatingMobileKitErrors { try await simulators.clearLocation(on: device) }
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        try await translatingMobileKitErrors {
            try await simulators.setAppearance(appearance.simulatorAppearance, on: device)
        }
    }

    public func openURL(device: String, url: String) async throws {
        try await translatingMobileKitErrors { try await simulators.openURL(url, on: device) }
    }

    // MARK: - App Inspection

    public func listInstalledAppIDs(device: String) async throws -> [String] {
        try await translatingMobileKitErrors { try await simulators.installedAppBundleIDs(on: device) }
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

private extension ImageFormat {
    var simulatorFormat: SimulatorImageFormat {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}

private extension Appearance {
    var simulatorAppearance: SimulatorAppearance {
        switch self {
        case .light: .light
        case .dark: .dark
        }
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
