import AmooCore
import Foundation

/// Host-side operations for driving this Mac's own desktop.
///
/// Everything inside the app (clicks, scrolling, accessibility queries, screenshots) goes through
/// the macOS companion, the same XCUITest runner as on iOS built for the Mac. What is left for the
/// host is starting and stopping apps. The Mac is never booted, shut down or reconfigured: amoo
/// would be changing the user's own machine, so those operations, and uninstalling, are refused.
///
/// Driving the desktop needs only what macOS itself requires of UI automation: Automation Mode
/// (`automationmodetool`), which `amoo preflight --platform macos` checks.
public struct MacHostBackend: IOSHostBackend {
    /// The device id this Mac goes by in device lists, hints and sessions.
    public static let deviceID = "mac"

    private let workspace: any MacWorkspace
    private let installed = InstalledMacApps()

    public init(workspace: any MacWorkspace = SystemMacWorkspace()) {
        self.workspace = workspace
    }

    // MARK: Device lifecycle

    /// The Mac is already running; there is nothing to boot.
    public func boot(device _: String) async throws {}

    public func shutdown(device _: String) async throws {
        throw Self.refused("device.shutdown", "amoo never shuts down the Mac it runs on")
    }

    public func deviceInfo(device _: String) async throws -> DeviceInfo {
        Self.currentDeviceInfo()
    }

    /// This Mac as a device: always booted, named after the computer.
    public static func currentDeviceInfo() -> DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = Host.current().localizedName ?? "This Mac"
        #else
        let name = ProcessInfo.processInfo.hostName
        #endif
        return DeviceInfo(
            id: deviceID,
            name: name,
            platform: .macos,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            state: .booted
        )
    }

    // MARK: App management

    /// Registers the `.app` bundle with Launch Services in place, so its bundle id resolves to this
    /// copy, and remembers it so a later launch opens exactly this build. Nothing is copied.
    public func installApp(device _: String, path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            throw AmooError.commandFailed(
                command: "install \(path)",
                output: "Not an app bundle with a bundle identifier."
            )
        }
        try workspace.register(appAt: url)
        await installed.record(bundleID: bundleID, url: url)
    }

    /// Quits any running instance first, so `arguments` and `environment` reach a fresh process,
    /// as `simctl launch --terminate-running-process` does on iOS.
    public func launchApp(
        device _: String,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        let recorded = await installed.url(bundleID: appID)
        guard let url = recorded ?? workspace.applicationURL(bundleID: appID) else {
            throw AmooError.appNotInstalled(appID: appID)
        }
        guard !workspace.isScreenLocked() else {
            throw AmooError.commandFailed(
                command: "launch \(appID)",
                output: "The Mac's screen is locked. Unlock it and start the session again;"
                    + " behind the lock screen no app window can be seen or driven."
            )
        }
        try await workspace.terminate(bundleID: appID)
        try await workspace.launch(appAt: url, arguments: Self.launchArguments(arguments), environment: environment)
    }

    /// `arguments`, with AppKit's saved window state ignored unless the caller decided otherwise.
    ///
    /// A relaunched app otherwise restores its windows where they were, including onto another
    /// Space, where neither accessibility nor XCUITest can see them: the session found an app with
    /// no windows at all. XCTest passes the same flag when it launches a Mac app itself.
    public static func launchArguments(_ arguments: [String]) -> [String] {
        guard !arguments.contains(ignorePersistedStateFlag) else { return arguments }
        return [ignorePersistedStateFlag, "YES"] + arguments
    }

    public static let ignorePersistedStateFlag = "-ApplePersistenceIgnoreState"

    public func terminateApp(device _: String, appID: String) async throws {
        try await workspace.terminate(bundleID: appID)
    }

    public func uninstallApp(device _: String, appID _: String) async throws {
        throw Self.refused("app.uninstall", "amoo does not delete apps from the Mac it runs on; remove it yourself")
    }

    public func listApps(device _: String) async throws -> [AppInfo] {
        workspace.runningApps()
    }

    // MARK: Capture

    /// The companion takes screenshots; capturing from the host would need Screen Recording access.
    public func screenshot(device _: String, format _: ImageFormat) async throws -> ScreenshotData {
        throw Self.refused("capture.hostScreenshot", "screenshots of the Mac come from the companion")
    }

    public func startRecording(device _: String, outputPath _: String) async throws -> Int32 {
        throw Self.refused("capture.recording", "screen recording is not available on macOS")
    }

    public func stopRecording(pid _: Int32) async throws {
        throw Self.refused("capture.recording", "screen recording is not available on macOS")
    }

    public var recordingFileExtension: String {
        "mov"
    }

    // MARK: Configuration

    public func setPermission(device _: String, change _: PermissionChange) async throws {
        throw Self.refused("config.permission", "privacy permissions on a Mac are granted in System Settings")
    }

    public func setLocation(device _: String, latitude _: Double, longitude _: Double) async throws {
        throw Self.refused("config.location", "amoo cannot simulate a location on a Mac")
    }

    public func clearLocation(device _: String) async throws {
        throw Self.refused("config.location", "amoo cannot simulate a location on a Mac")
    }

    public func setAppearance(device _: String, appearance _: Appearance) async throws {
        throw Self.refused("config.appearance", "amoo does not change the Mac's system appearance")
    }

    public func openURL(device _: String, url: String) async throws {
        guard let parsed = URL(string: url), parsed.scheme != nil else {
            throw AmooError.commandFailed(command: "open \(url)", output: "Not a URL with a scheme.")
        }
        try await workspace.open(parsed)
    }

    private static func refused(_ key: String, _ reason: String) -> AmooError {
        .unsupportedCapability(key: key, reason: reason)
    }
}

/// App bundles installed through this backend, by bundle id.
private actor InstalledMacApps {
    private var urls: [String: URL] = [:]

    func record(bundleID: String, url: URL) {
        urls[bundleID] = url
    }

    func url(bundleID: String) -> URL? {
        urls[bundleID]
    }
}
