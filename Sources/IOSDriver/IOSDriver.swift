import CompanionProtocol
import Foundation
import MobileTestingCore
import ProcessRunner

public actor IOSDriver: PlatformDriver {
    private struct ActiveRecording {
        let pid: Int32
        let outputPath: String
    }

    private let companion: any CompanionClient
    private let simctl: any SimctlRunning
    private let deviceID: String
    private var activeRecordings: [String: ActiveRecording] = [:] // sessionID → recording
    private var currentAppID: String?

    public init(
        companion: any CompanionClient,
        simctl: any SimctlRunning = SimctlRunner(),
        deviceID: String = "booted"
    ) {
        self.companion = companion
        self.simctl = simctl
        self.deviceID = deviceID
    }

    // MARK: - DeviceDriver

    public func boot() async throws {
        try await simctl.bootStatus(device: deviceID)
    }

    public func shutdown() async throws {
        try await simctl.shutdown(device: deviceID)
    }

    public func deviceInfo() async throws -> DeviceInfo {
        let json = try await simctl.listDevices()
        return parseDeviceInfo(json: json, deviceID: deviceID)
    }

    // MARK: - App Management

    public func installApp(path: String) async throws {
        try await simctl.install(device: deviceID, appPath: path)
    }

    public func launchApp(
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        try await simctl.launch(
            device: deviceID,
            appID: appID,
            arguments: arguments,
            environment: environment
        )
        currentAppID = appID
    }

    public func terminateApp(appID: String) async throws {
        try await simctl.terminate(device: deviceID, appID: appID)
    }

    public func uninstallApp(appID: String) async throws {
        try await simctl.uninstall(device: deviceID, appID: appID)
    }

    public func listApps() async throws -> [AppInfo] {
        let output = try await simctl.listApps(device: deviceID)
        return parseAppList(plistOutput: output)
    }

    public func appState(appID _: String) async throws -> AppState {
        .unknown
    }

    // MARK: - Touch Actions (delegate to companion)

    public func tap(at point: Point) async throws {
        try await companion.tap(at: point)
    }

    public func doubleTap(at point: Point) async throws {
        try await companion.doubleTap(at: point)
    }

    public func longPress(at point: Point, duration: Duration) async throws {
        try await companion.longPress(at: point, duration: duration)
    }

    public func tapElement(_ selector: ElementSelector) async throws {
        let context = try await appQueryContext()
        try await companion.tapElement(selector, appID: context.appID, candidateBundleIDs: context.candidateBundleIDs)
    }

    // MARK: - Gesture Actions (delegate to companion)

    public func swipe(from: Point, to: Point, duration: Duration) async throws {
        try await companion.swipe(from: from, to: to, duration: duration)
    }

    public func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: nil)
    }

    public func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: element)
    }

    public func scroll(direction: Direction, distance: Double) async throws {
        try await companion.scroll(direction: direction, distance: distance)
    }

    // MARK: - Text Actions (delegate to companion)

    public func typeText(_ text: String) async throws {
        try await companion.typeText(text)
    }

    public func clearText(characterCount: Int?) async throws {
        try await companion.clearText(characterCount: characterCount)
    }

    // MARK: - Navigation Actions

    public func pressBack() async throws {
        try await companion.pressBack()
    }

    public func pressHome() async throws {
        try await companion.pressHome()
        currentAppID = nil
    }

    public func openURL(_ url: String) async throws {
        try await simctl.openURL(device: deviceID, url: url)
    }

    // MARK: - Screen Capture

    public func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
        // Prefer companion screenshot (XCUIScreen) — simctl screenshot can time out when XCUITest is active
        do {
            return try await companion.takeScreenshot()
        } catch {
            // Fall back to simctl if companion doesn't support screenshots
            let data = try await simctl.screenshot(device: deviceID, format: format)
            return ScreenshotData(bytes: [UInt8](data), format: format)
        }
    }

    public func startRecording() async throws -> RecordingSession {
        guard activeRecordings.isEmpty else {
            throw MobileTestingError.commandFailed(
                command: "startRecording",
                output: "Only one active iOS recording is supported per driver."
            )
        }

        let sessionID = UUID().uuidString
        let outputPath = NSTemporaryDirectory() + "recording_\(sessionID).mov"
        let pid = try await simctl.startRecording(device: deviceID, outputPath: outputPath)
        activeRecordings[sessionID] = ActiveRecording(pid: pid, outputPath: outputPath)
        return RecordingSession(id: sessionID, deviceID: deviceID)
    }

    public func stopRecording(sessionID: String) async throws -> String {
        guard let recording = activeRecordings.removeValue(forKey: sessionID) else {
            throw MobileTestingError.commandFailed(
                command: "stopRecording",
                output: "No active recording with session ID: \(sessionID)"
            )
        }

        try await simctl.stopRecording(pid: recording.pid)
        return recording.outputPath
    }

    // MARK: - Accessibility (delegate to companion)

    public func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let context = try await appQueryContext()
        return try await companion.findElements(
            selector,
            appID: context.appID,
            candidateBundleIDs: context.candidateBundleIDs
        )
    }

    public func getViewHierarchy() async throws -> ViewNode {
        // If we tracked an explicit launch, use it directly.
        if let appID = currentAppID {
            return try await companion.getViewHierarchy(appID: appID, candidateBundleIDs: [])
        }
        return try await companion.getViewHierarchy(appID: nil, candidateBundleIDs: [])
    }

    public func elementExists(_ selector: ElementSelector) async throws -> Bool {
        let context = try await appQueryContext()
        let elements = try await companion.findElements(
            selector,
            appID: context.appID,
            candidateBundleIDs: context.candidateBundleIDs
        )
        return !elements.isEmpty
    }

    public func waitForElement(_ selector: ElementSelector, timeout: Duration) async throws {
        let context = try await appQueryContext()
        try await companion.waitForElement(
            selector,
            timeout: timeout,
            appID: context.appID,
            candidateBundleIDs: context.candidateBundleIDs
        )
    }

    public func waitForElementToDisappear(_ selector: ElementSelector, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout.milliseconds) / 1000.0)
        let context = try await appQueryContext()
        while Date() < deadline {
            let elements = try await companion.findElements(
                selector,
                appID: context.appID,
                candidateBundleIDs: context.candidateBundleIDs
            )
            if elements.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MobileTestingError.timeout(operation: "waitForElementToDisappear", duration: timeout)
    }

    public func isKeyboardVisible() async throws -> Bool {
        try await companion.isKeyboardVisible()
    }

    // MARK: - Configuration

    public func setPermission(_ change: PermissionChange) async throws {
        let action = change.granted ? "grant" : "revoke"
        try await simctl.setPermission(
            device: deviceID,
            action: action,
            permission: change.permission,
            appID: change.appID
        )
    }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        try await simctl.setLocation(device: deviceID, latitude: latitude, longitude: longitude)
    }

    public func clearLocation() async throws {
        try await simctl.clearLocation(device: deviceID)
    }

    public func setAppearance(_ appearance: Appearance) async throws {
        try await simctl.setAppearance(device: deviceID, appearance: appearance)
    }

    // MARK: - AI Context (delegate to companion)

    public func getScreenContext() async throws -> ScreenContext {
        try await companion.getScreenContext()
    }

    public func getInteractableElements() async throws -> [ElementInfo] {
        try await companion.getInteractableElements()
    }

    public func findByDescription(_ description: String) async throws -> [ElementInfo] {
        try await companion.findByDescription(description)
    }
}

// MARK: - Parsing Helpers

extension IOSDriver {
    private func appQueryContext() async throws -> (appID: String?, candidateBundleIDs: [String]) {
        if let currentAppID {
            return (currentAppID, [])
        }

        return (nil, [])
    }

    func parseDeviceInfo(json: String, deviceID: String) -> DeviceInfo {
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
    private func parseRuntimeVersion(_ runtime: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtime.hasPrefix(prefix) else { return runtime }
        let suffix = runtime.dropFirst(prefix.count)
        // suffix looks like "iOS-17-2" / "watchOS-10-0" — drop the OS-name segment.
        guard let dashIndex = suffix.firstIndex(of: "-") else { return String(suffix) }
        let version = suffix[suffix.index(after: dashIndex)...]
        return version.replacingOccurrences(of: "-", with: ".")
    }

    func parseAppList(plistOutput: String) -> [AppInfo] {
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

        // Fallback: extract CFBundleIdentifier from plist text
        var apps: [AppInfo] = []
        let lines = plistOutput.components(separatedBy: "\n")
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
}
