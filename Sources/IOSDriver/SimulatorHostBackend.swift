import AmooCore
import Foundation
import ProcessRunner

/// ``IOSHostBackend`` for iOS *simulators*, driven by `xcrun simctl`.
///
/// This backend supports the full protocol — simulators are the more capable of the two
/// targets, since `simctl` can reach into privacy settings that no physical-device tool exposes.
public struct SimulatorHostBackend: IOSHostBackend {
    private let simctl: any SimctlRunning

    public init(simctl: any SimctlRunning = SimctlRunner()) {
        self.simctl = simctl
    }

    public var recordingFileExtension: String {
        "mov"
    }

    // MARK: - Device Lifecycle

    public func boot(device: String) async throws {
        try await simctl.bootStatus(device: device)
    }

    public func shutdown(device: String) async throws {
        try await simctl.shutdown(device: device)
    }

    public func deviceInfo(device: String) async throws -> DeviceInfo {
        let json = try await simctl.listDevices()
        return Self.parseDeviceInfo(json: json, deviceID: device)
    }

    // MARK: - App Management

    public func installApp(device: String, path: String) async throws {
        try await simctl.install(device: device, appPath: path)
    }

    public func launchApp(
        device: String,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws {
        try await simctl.launch(
            device: device,
            appID: appID,
            arguments: arguments,
            environment: environment
        )
    }

    public func terminateApp(device: String, appID: String) async throws {
        try await simctl.terminate(device: device, appID: appID)
    }

    public func uninstallApp(device: String, appID: String) async throws {
        try await simctl.uninstall(device: device, appID: appID)
    }

    public func listApps(device: String) async throws -> [AppInfo] {
        let output = try await simctl.listApps(device: device)
        return Self.parseAppList(plistOutput: output)
    }

    // MARK: - Capture

    public func screenshot(device: String, format: ImageFormat) async throws -> ScreenshotData {
        let data = try await simctl.screenshot(device: device, format: format)
        return ScreenshotData(bytes: [UInt8](data), format: format)
    }

    public func startRecording(device: String, outputPath: String) async throws -> Int32 {
        try await simctl.startRecording(device: device, outputPath: outputPath)
    }

    public func stopRecording(pid: Int32) async throws {
        try await simctl.stopRecording(pid: pid)
    }

    // MARK: - Configuration

    public func setPermission(device: String, change: PermissionChange) async throws {
        try await simctl.setPermission(
            device: device,
            action: change.granted ? "grant" : "revoke",
            permission: change.permission,
            appID: change.appID
        )
    }

    public func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        try await simctl.setLocation(device: device, latitude: latitude, longitude: longitude)
    }

    public func clearLocation(device: String) async throws {
        try await simctl.clearLocation(device: device)
    }

    public func setAppearance(device: String, appearance: Appearance) async throws {
        try await simctl.setAppearance(device: device, appearance: appearance)
    }

    public func openURL(device: String, url: String) async throws {
        try await simctl.openURL(device: device, url: url)
    }
}

// MARK: - Parsing Helpers

extension SimulatorHostBackend {
    static func parseDeviceInfo(json: String, deviceID: String) -> DeviceInfo {
        // Parse simctl list devices -j output
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["devices"] as? [String: [[String: Any]]]
        else {
            // JSON parse failed — we genuinely don't know the device state.
            return DeviceInfo(id: deviceID, name: deviceID, platform: .ios, osVersion: "unknown", state: .unknown)
        }

        for (runtime, deviceList) in devices {
            for device in deviceList {
                let udid = device["udid"] as? String ?? ""
                let state = device["state"] as? String ?? ""
                let isMatch = udid == deviceID || (deviceID == "booted" && state == "Booted")
                if isMatch {
                    let name = device["name"] as? String ?? deviceID
                    let osVersion = parseRuntimeVersion(runtime)
                    let deviceState: DeviceState = state == "Booted" ? .booted : .shutdown
                    return DeviceInfo(id: udid, name: name, platform: .ios, osVersion: osVersion, state: deviceState)
                }
            }
        }

        // Device not found in the list — we can't claim it's booted.
        return DeviceInfo(id: deviceID, name: deviceID, platform: .ios, osVersion: "unknown", state: .unknown)
    }

    /// Strip the `com.apple.CoreSimulator.SimRuntime.<OS>-` prefix and convert the
    /// remaining `<major>-<minor>` to a dotted version. Handles iOS, watchOS, tvOS,
    /// and visionOS so callers see clean version strings rather than the raw bundle id.
    private static func parseRuntimeVersion(_ runtime: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtime.hasPrefix(prefix) else { return runtime }
        let suffix = runtime.dropFirst(prefix.count)
        // suffix looks like "iOS-17-2" / "watchOS-10-0" — drop the OS-name segment.
        guard let dashIndex = suffix.firstIndex(of: "-") else { return String(suffix) }
        let version = suffix[suffix.index(after: dashIndex)...]
        return version.replacingOccurrences(of: "-", with: ".")
    }

    static func parseAppList(plistOutput: String) -> [AppInfo] {
        // simctl listapps returns plist-formatted output; parse bundle IDs
        guard let data = plistOutput.data(using: .utf8) else { return [] }

        // Try JSON format first (newer simctl versions with -j flag)
        if let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return apps.compactMap { dict in
                guard let bundleID = dict["CFBundleIdentifier"] as? String else { return nil }
                let name = dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String
                let version = dict["CFBundleShortVersionString"] as? String
                return AppInfo(appID: bundleID, name: name, version: version)
            }
        }

        // Try JSON dictionary format (simctl listapps on newer Xcode returns {bundleID: {info}})
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            return root.compactMap { _, dict in
                guard let bundleID = dict["CFBundleIdentifier"] as? String else { return nil }
                let name = dict["CFBundleDisplayName"] as? String ?? dict["CFBundleName"] as? String
                let version = dict["CFBundleShortVersionString"] as? String
                return AppInfo(appID: bundleID, name: name, version: version)
            }
        }

        // Fallback: old-style property list text format (key = "value";)
        // Extracts CFBundleIdentifier from lines like: CFBundleIdentifier = "com.example.app";
        let lines = plistOutput.components(separatedBy: "\n")
        var apps = parseOldStylePlistApps(lines: lines)

        // Fallback: XML plist format with <string> tags
        if apps.isEmpty {
            apps = parseXMLPlistFallbackApps(lines: lines)
        }

        return apps
    }

    /// Parses old-style property list text format (key = "value";), extracting bundle entries
    /// from lines like: CFBundleIdentifier = "com.example.app";
    private static func parseOldStylePlistApps(lines: [String]) -> [AppInfo] {
        var apps: [AppInfo] = []
        var currentBundleID: String?
        var currentName: String?
        var currentVersion: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let value = extractOldPlistValue(trimmed, key: "CFBundleIdentifier") {
                // If we had a previous bundle ID pending, save it
                if let bundleID = currentBundleID {
                    apps.append(AppInfo(appID: bundleID, name: currentName, version: currentVersion))
                }
                currentBundleID = value
                currentName = nil
                currentVersion = nil
            } else if let value = extractOldPlistValue(trimmed, key: "CFBundleDisplayName") {
                currentName = value
            } else if let value = extractOldPlistValue(trimmed, key: "CFBundleName"), currentName == nil {
                currentName = value
            } else if let value = extractOldPlistValue(trimmed, key: "CFBundleShortVersionString") {
                currentVersion = value
            } else if trimmed == "};" || trimmed == "}" {
                // End of an app entry
                if let bundleID = currentBundleID {
                    apps.append(AppInfo(appID: bundleID, name: currentName, version: currentVersion))
                    currentBundleID = nil
                    currentName = nil
                    currentVersion = nil
                }
            }
        }
        // Capture last entry if not terminated by };
        if let bundleID = currentBundleID {
            apps.append(AppInfo(appID: bundleID, name: currentName, version: currentVersion))
        }

        return apps
    }

    /// Parses XML plist format with `<string>` tags as a last-resort fallback.
    private static func parseXMLPlistFallbackApps(lines: [String]) -> [AppInfo] {
        var apps: [AppInfo] = []
        var foundKey = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("CFBundleIdentifier") {
                foundKey = true
                continue
            }
            if foundKey {
                if let start = trimmed.range(of: "<string>"),
                   let end = trimmed.range(of: "</string>") {
                    let bundleID = String(trimmed[start.upperBound ..< end.lowerBound])
                    apps.append(AppInfo(appID: bundleID))
                }
                foundKey = false
            }
        }
        return apps
    }

    /// Extracts a value from old-style plist text format: `Key = "value";` or `Key = value;`
    private static func extractOldPlistValue(_ line: String, key: String) -> String? {
        // Match patterns like:
        //   CFBundleIdentifier = "com.example.app";
        //   CFBundleDisplayName = SampleApp;
        guard line.contains(key) else { return nil }
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let keyPart = parts[0].trimmingCharacters(in: .whitespaces)
        guard keyPart == key else { return nil }
        var value = parts[1].trimmingCharacters(in: .whitespaces)
        // Remove trailing semicolons
        if value.hasSuffix(";") {
            value = String(value.dropLast())
        }
        value = value.trimmingCharacters(in: .whitespaces)
        // Remove surrounding quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
