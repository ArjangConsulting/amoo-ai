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
    /// Larger Accessibility Sizes as first read per device, so restoring a standard text size also
    /// puts that toggle back instead of leaving it switched on.
    private let largerSizesBaseline = LargerAccessibilitySizesBaseline()

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

    // MARK: - Display settings

    public func displaySetting(device: String, setting: DisplaySetting) async throws -> String {
        let json = try await devicectl.appearanceSettings(device: device)
        guard let settings = Self.parseAppearance(json: json) else {
            throw AmooError.unsupportedCapability(
                key: "config.\(setting.rawValue)",
                reason: "devicectl did not report the device's appearance settings; update Xcode."
            )
        }
        await largerSizesBaseline.record(settings.largerSizes, for: device)
        guard let value = settings.values[setting] else {
            throw AmooError.unsupportedCapability(
                key: "config.\(setting.rawValue)", reason: "devicectl did not report \(setting.rawValue)."
            )
        }
        return value
    }

    public func setDisplaySetting(device: String, setting: DisplaySetting, value: String) async throws -> String {
        guard let canonical = setting.canonicalValue(value, for: .ios) else {
            throw AmooError.commandFailed(
                command: "devicectl device settings appearance", output: "'\(value)' is not a value iOS accepts."
            )
        }
        let largerSizesWereOn = await largerSizesBaseline.value(for: device) == true
        let options: [String] = switch setting {
        case .appearance:
            ["--mode", canonical]
        case .increaseContrast:
            ["--increase-contrast", canonical == "enabled" ? "on" : "off"]
        case .textSize:
            // Accessibility sizes need Larger Accessibility Sizes on; a standard size gets the
            // toggle back as it was first read.
            ["--text-size", canonical, "--larger-accessibility-sizes"] + [
                canonical.hasPrefix("accessibility-") || largerSizesWereOn ? "on" : "off"
            ]
        }
        try await devicectl.setAppearanceSettings(device: device, options: options)
        return try await displaySetting(device: device, setting: setting)
    }

    /// Parses `devicectl device info appearance --json-output -`. Text sizes arrive as display names
    /// ("Accessibility Extra Large") and become the content-size spelling simctl also uses.
    static func parseAppearance(json: String) -> (values: [DisplaySetting: String], largerSizes: Bool?)? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any] else { return nil }
        var values: [DisplaySetting: String] = [:]
        if let style = (result["userInterfaceStyle"] as? String)?.lowercased(), ["light", "dark"].contains(style) {
            values[.appearance] = style
        }
        if let size = result["textSize"] as? String {
            let spelled = size.lowercased().split(separator: " ").joined(separator: "-")
            if DisplaySetting.iosTextSizes.contains(spelled) {
                values[.textSize] = spelled
            }
        }
        if let contrast = result["increaseContrast"] as? Bool {
            values[.increaseContrast] = contrast ? "enabled" : "disabled"
        }
        return (values, result["largerAccessibilitySizesEnabled"] as? Bool)
    }
}

/// The first Larger Accessibility Sizes value read per device.
private actor LargerAccessibilitySizesBaseline {
    private var values: [String: Bool] = [:]

    func record(_ value: Bool?, for device: String) {
        guard let value, values[device] == nil else { return }
        values[device] = value
    }

    func value(for device: String) -> Bool? {
        values[device]
    }
}
