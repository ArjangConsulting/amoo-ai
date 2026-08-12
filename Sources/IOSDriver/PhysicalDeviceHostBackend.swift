import AmooCore
import Foundation
import ProcessRunner

/// ``IOSHostBackend`` for *physical* iOS devices, driven by `xcrun devicectl`.
///
/// Covers the protocol except ``setPermission(device:change:)``: `simctl privacy` grants and
/// revokes TCC permissions on a simulator, and `devicectl` has no equivalent — its
/// `device settings` surface is appearance, audio, biometrics, VoiceOver, and reset.
/// Rather than no-op, that call fails loudly so tests don't silently run against the wrong
/// permission state.
public struct PhysicalDeviceHostBackend: IOSHostBackend {
    private let devicectl: any DeviceCtlRunning

    public init(devicectl: any DeviceCtlRunning = DeviceCtlRunner()) {
        self.devicectl = devicectl
    }

    /// `devicectl device capture screen-record` rejects any destination that isn't `.mp4`.
    public var recordingFileExtension: String {
        "mp4"
    }

    // MARK: - Device Lifecycle

    /// No-op: a physical device is either powered on and connected, or it isn't reachable
    /// at all. There is nothing for the host to boot.
    public func boot(device _: String) async throws {}

    /// Not supported. `devicectl device reboot` exists, but shutting a device down would
    /// end the session with no way to bring it back, so this is deliberately inert.
    public func shutdown(device _: String) async throws {}

    public func deviceInfo(device: String) async throws -> DeviceInfo {
        let json = try await devicectl.listDevices()
        return Self.parseDeviceInfo(json: json, deviceID: device)
    }

    // MARK: - App Management

    public func installApp(device: String, path: String) async throws {
        try await devicectl.install(device: device, appPath: path)
    }

    public func launchApp(
        device: String,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await devicectl.launch(
            device: device,
            appID: appID,
            arguments: arguments,
            environment: environment
        )
    }

    public func terminateApp(device: String, appID: String) async throws {
        try await devicectl.terminate(device: device, appID: appID)
    }

    public func uninstallApp(device: String, appID: String) async throws {
        try await devicectl.uninstall(device: device, appID: appID)
    }

    public func listApps(device: String) async throws -> [AppInfo] {
        let json = try await devicectl.listApps(device: device)
        return Self.parseAppList(json: json)
    }

    // MARK: - Capture

    public func screenshot(device: String, format _: ImageFormat) async throws -> ScreenshotData {
        // devicectl only writes PNG, so the requested format is not honoured. The
        // ScreenCapture contract documents `format` as a request, not a guarantee, and
        // requires callers to read the format actually returned.
        let data = try await devicectl.screenshot(device: device)
        return ScreenshotData(bytes: [UInt8](data), format: .png)
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        try await devicectl.startRecording(device: device, outputPath: outputPath)
    }

    public func stopRecording(pid: Int32) async throws {
        try await devicectl.stopRecording(pid: pid)
    }

    // MARK: - Configuration

    public func setPermission(device _: String, change: PermissionChange) async throws {
        throw AmooError.unsupportedCapability(
            key: "config.setPermission",
            reason: """
            Setting app permissions is simulator-only: `simctl privacy` has no `devicectl` \
            equivalent, so permission '\(change.permission)' for '\(change.appID)' cannot be \
            changed on a physical device from the host.
            Grant or revoke it manually in Settings on the device, or run this test against \
            a simulator.
            """
        )
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        try await devicectl.setLocation(device: device, latitude: latitude, longitude: longitude)
    }

    public func clearLocation(device: String) async throws {
        try await devicectl.clearLocation(device: device)
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        try await devicectl.setAppearance(device: device, appearance: appearance)
    }

    public func openURL(device: String, url: String) async throws {
        try await devicectl.openURL(device: device, url: url)
    }
}

// MARK: - Parsing Helpers

package extension PhysicalDeviceHostBackend {
    /// Parses `devicectl list devices --json-output`.
    ///
    /// A device matches on UDID, identifier, or name, so callers can use whichever
    /// `devicectl` itself accepts for `--device`.
    static func parseDeviceInfo(json: String, deviceID: String) -> DeviceInfo {
        let unknown = DeviceInfo(
            id: deviceID, name: deviceID, platform: .ios, osVersion: "unknown", state: .unknown
        )

        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return unknown }

        for device in devices {
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let identifier = device["identifier"] as? String ?? ""
            let udid = hardware["udid"] as? String ?? ""
            let name = properties["name"] as? String ?? deviceID

            guard deviceID == udid || deviceID == identifier || deviceID == name else { continue }

            let osVersion = properties["osVersionNumber"] as? String ?? "unknown"
            // connectionProperties.tunnelState is "connected" when the device is
            // reachable; anything else means we can't drive it.
            let connection = device["connectionProperties"] as? [String: Any] ?? [:]
            let tunnelState = connection["tunnelState"] as? String ?? ""
            let state: DeviceState = tunnelState == "connected" ? .booted : .shutdown

            return DeviceInfo(
                id: udid.isEmpty ? identifier : udid,
                name: name,
                platform: .ios,
                osVersion: osVersion,
                state: state
            )
        }

        return unknown
    }

    /// Parses `devicectl device info apps --json-output`.
    static func parseAppList(json: String) -> [AppInfo] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]]
        else { return [] }

        return apps.compactMap { app in
            guard let bundleID = app["bundleIdentifier"] as? String else { return nil }
            let name = app["name"] as? String
            let version = app["version"] as? String
            return AppInfo(appID: bundleID, name: name, version: version)
        }
    }
}
