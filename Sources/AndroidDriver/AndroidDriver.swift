import CompanionProtocol
import Foundation
import MobileTestingCore
import ProcessRunner

public actor AndroidDriver: PlatformDriver {
    private struct ActiveRecording {
        let remotePath: String
        let localPath: String
    }

    private let companion: any CompanionClient
    private let adb: any ADBRunning
    private let serial: String?
    private var activeRecordings: [String: ActiveRecording] = [:]

    public init(
        companion: any CompanionClient,
        adb: any ADBRunning = ADBRunner(),
        serial: String? = nil
    ) {
        self.companion = companion
        self.adb = adb
        self.serial = serial
    }

    // MARK: - DeviceDriver

    public func boot() async throws {
        try await adb.startServer()
    }

    public func shutdown() async throws {
        try await adb.killEmulator(serial: serial)
    }

    public func deviceInfo() async throws -> DeviceInfo {
        _ = try await adb.listDevices()
        return DeviceInfo(
            id: serial ?? "default",
            name: serial ?? "default",
            platform: .android,
            osVersion: "unknown",
            state: .booted
        )
    }

    // MARK: - App Management

    public func installApp(path: String) async throws {
        try await adb.install(serial: serial, apkPath: path)
    }

    public func launchApp(appID: String, arguments: [String] = [], environment _: [String: String] = [:]) async throws {
        try await adb.launch(serial: serial, appID: appID, arguments: arguments)
    }

    public func terminateApp(appID: String) async throws {
        try await adb.terminate(serial: serial, appID: appID)
    }

    public func uninstallApp(appID: String) async throws {
        try await adb.uninstall(serial: serial, appID: appID)
    }

    public func listApps() async throws -> [AppInfo] {
        let output = try await adb.listPackages(serial: serial)
        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> AppInfo? in
                let pkg = line
                    .replacingOccurrences(of: "package:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pkg.isEmpty else { return nil }
                return AppInfo(appID: pkg)
            }
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
        try await companion.tapElement(selector)
    }

    // MARK: - Gesture Actions (delegate to companion)

    public func swipe(from: Point, to: Point, duration: Duration) async throws {
        try await companion.swipe(from: from, to: to, duration: duration)
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
        _ = try await adb.run(adbArgs() + ["shell", "input", "keyevent", "KEYCODE_HOME"])
    }

    public func openURL(_ url: String) async throws {
        try await adb.openURL(serial: serial, url: url)
    }

    // MARK: - Screen Capture

    public func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        let data = try await adb.screenshot(serial: serial)
        return ScreenshotData(bytes: [UInt8](data), format: .png)
    }

    public func startRecording() async throws -> RecordingSession {
        guard activeRecordings.isEmpty else {
            throw MobileTestingError.commandFailed(
                command: "startRecording",
                output: "Only one active Android recording is supported per driver."
            )
        }

        let sessionID = UUID().uuidString
        // /data/local/tmp is owned by the shell user — other apps on the device can't
        // read recordings there. /sdcard is world-readable to apps with storage perms,
        // and recordings can contain on-screen secrets typed during the test.
        let remotePath = "/data/local/tmp/recording_\(sessionID).mp4"
        let localPath = NSTemporaryDirectory() + "recording_\(sessionID).mp4"
        try await adb.startRecording(serial: serial, outputPath: remotePath)
        activeRecordings[sessionID] = ActiveRecording(remotePath: remotePath, localPath: localPath)
        return RecordingSession(id: sessionID, deviceID: serial ?? "default")
    }

    public func stopRecording(sessionID: String) async throws -> String {
        guard let recording = activeRecordings.removeValue(forKey: sessionID) else {
            throw MobileTestingError.commandFailed(
                command: "stopRecording",
                output: "No active recording with session ID: \(sessionID)"
            )
        }

        try await adb.stopRecording(serial: serial)
        _ = try await adb.run(adbArgs() + ["pull", recording.remotePath, recording.localPath])
        // Best-effort cleanup; don't fail the call if the device-side rm fails.
        _ = try? await adb.run(adbArgs() + ["shell", "rm", recording.remotePath])
        return recording.localPath
    }

    // MARK: - Accessibility (delegate to companion)

    public func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await companion.findElements(selector)
    }

    public func getViewHierarchy() async throws -> ViewNode {
        try await companion.getViewHierarchy(appID: nil, candidateBundleIDs: [])
    }

    public func elementExists(_ selector: ElementSelector) async throws -> Bool {
        let elements = try await companion.findElements(selector)
        return !elements.isEmpty
    }

    public func waitForElement(_ selector: ElementSelector, timeout: Duration) async throws {
        try await companion.waitForElement(selector, timeout: timeout)
    }

    public func waitForElementToDisappear(_ selector: ElementSelector, timeout: Duration) async throws {
        let deadline = Date().addingTimeInterval(Double(timeout.milliseconds) / 1000.0)
        while Date() < deadline {
            let elements = try await companion.findElements(selector)
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
        if change.granted {
            try await adb.grantPermission(serial: serial, appID: change.appID, permission: change.permission)
        } else {
            try await adb.revokePermission(serial: serial, appID: change.appID, permission: change.permission)
        }
    }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        _ = try await adb.run(adbArgs() + [
            "emu", "geo", "fix", String(longitude), String(latitude)
        ])
    }

    public func clearLocation() async throws {
        // No direct clear on Android emulator; set to 0,0
        try await setLocation(latitude: 0, longitude: 0)
    }

    public func setAppearance(_ appearance: Appearance) async throws {
        let mode = appearance == .dark ? "yes" : "no"
        _ = try await adb.run(adbArgs() + [
            "shell", "cmd", "uimode", "night", mode
        ])
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

    // MARK: - Private

    private func adbArgs() -> [String] {
        if let serial {
            return ["-s", serial]
        }
        return []
    }
}
