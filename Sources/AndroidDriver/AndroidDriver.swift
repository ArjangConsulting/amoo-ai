import AmooCore
import CompanionProtocol
import Foundation
import ProcessRunner

public actor AndroidDriver: PlatformDriver {
    private struct ActiveRecording {
        let remotePath: String
        let localPath: String
    }

    private let companion: any CompanionClient
    let adb: any ADBRunning
    let requestedDeviceID: String?
    private let emulator: any EmulatorRunning
    var resolvedSerial: String?
    private var activeRecordings: [String: ActiveRecording] = [:]

    public init(
        companion: any CompanionClient,
        adb: any ADBRunning = ADBRunner(),
        emulator: any EmulatorRunning = EmulatorRunner(),
        serial: String? = nil
    ) {
        self.companion = companion
        self.adb = adb
        self.emulator = emulator
        requestedDeviceID = serial
    }

    // MARK: - DeviceDriver

    public func boot() async throws {
        try await adb.startServer()
        let devices = try await connectedDevices()
        if let requestedDeviceID,
           let connected = devices.first(where: { $0.serial == requestedDeviceID && $0.state == "device" }) {
            resolvedSerial = connected.serial
            return
        }
        if requestedDeviceID == nil, let connected = devices.first(where: { $0.state == "device" }) {
            resolvedSerial = connected.serial
            return
        }

        guard let avdName = requestedDeviceID, !avdName.hasPrefix("emulator-") else {
            throw AmooError.commandFailed(
                command: "device_boot",
                output: "Requested Android device is not connected: \(requestedDeviceID ?? "default")"
            )
        }
        let port = nextEmulatorPort(devices: devices)
        try await emulator.launch(avdName: avdName, port: port)
        let launchedSerial = "emulator-\(port)"
        try await waitForBoot(serial: launchedSerial, timeoutSeconds: 120)
        resolvedSerial = launchedSerial
    }

    public func shutdown() async throws {
        try await adb.killEmulator(serial: activeSerial)
    }

    public func deviceInfo() async throws -> DeviceInfo {
        let devices = try await connectedDevices()
        guard let device = devices.first(where: { $0.serial == activeSerial && $0.state == "device" }) else {
            throw AmooError.commandFailed(
                command: "deviceInfo",
                output: "Android device is not connected: \(activeSerial ?? "default")"
            )
        }
        return DeviceInfo(
            id: device.serial,
            name: requestedDeviceID ?? device.serial,
            platform: .android,
            osVersion: "unknown",
            state: .booted
        )
    }

    // MARK: - App Management

    public func installApp(path: String) async throws {
        try await adb.install(serial: activeSerial, apkPath: path)
    }

    public func launchApp(appID: String, arguments: [String] = [], environment _: [String: String] = [:]) async throws {
        if arguments.isEmpty {
            try await adb.launchResetting(serial: activeSerial, appID: appID)
        } else {
            try await adb.launch(serial: activeSerial, appID: appID, arguments: arguments)
        }
    }

    public func terminateApp(appID: String) async throws {
        try await adb.terminate(serial: activeSerial, appID: appID)
    }

    public func uninstallApp(appID: String) async throws {
        try await adb.uninstall(serial: activeSerial, appID: appID)
    }

    public func listApps() async throws -> [AppInfo] {
        let output = try await adb.listPackages(serial: activeSerial)
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

    public func appState(appID: String) async throws -> AppState {
        // `pidof` exits non-zero when the package has no live process, and adb propagates that
        // exit code — so a "not running" answer arrives as a thrown ShellError, not empty stdout.
        let process = try? await adb.run(adbArgs() + ["shell", "pidof", appID])
        if let stdout = process?.stdout, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .running
        }
        let packages = try await adb.listPackages(serial: activeSerial)
        return packages.split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "package:\(appID)" }
            ? .notRunning
            : .notInstalled
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

    public func tapElement(_ selector: ElementSelector, appID: String?) async throws {
        try await companion.tapElement(selector, appID: appID, candidateBundleIDs: [])
    }

    // MARK: - Gesture Actions (delegate to companion)

    public func swipe(from: Point, to: Point, duration: Duration) async throws {
        try await companion.swipe(from: from, to: to, duration: duration)
    }

    public func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: nil)
    }

    public func swipe(
        direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: element)
    }

    public func scroll(direction: Direction, distance: Double) async throws {
        try await companion.scroll(direction: direction, distance: distance)
    }

    public func drag(from: Point, to: Point, duration: Duration, holdDuration: Duration) async throws {
        try await companion.drag(from: from, to: to, duration: duration, holdDuration: holdDuration)
    }

    // MARK: - Text Actions (delegate to companion)

    public func typeText(_ text: String) async throws {
        try await companion.typeText(text)
    }

    public func clearText(characterCount: Int?) async throws {
        try await companion.clearText(characterCount: characterCount)
    }

    public func setText(_ selector: ElementSelector, text: String) async throws {
        try await companion.setText(selector, text: text, appID: nil, candidateBundleIDs: [])
    }

    // MARK: - Navigation Actions

    public func pressBack() async throws {
        try await companion.pressBack()
    }

    public func pressHome() async throws {
        _ = try await adb.run(adbArgs() + ["shell", "input", "keyevent", "KEYCODE_HOME"])
    }

    public func openURL(_ url: String) async throws {
        try await adb.openURL(serial: activeSerial, url: url)
    }

    // MARK: - Screen Capture

    public func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        let data = try await adb.screenshot(serial: activeSerial)
        return ScreenshotData(bytes: [UInt8](data), format: .png)
    }

    public func startRecording() async throws -> RecordingSession {
        guard activeRecordings.isEmpty else {
            throw AmooError.commandFailed(
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
        try await adb.startRecording(serial: activeSerial, outputPath: remotePath)
        activeRecordings[sessionID] = ActiveRecording(remotePath: remotePath, localPath: localPath)
        return RecordingSession(id: sessionID, deviceID: activeSerial ?? "default")
    }

    public func stopRecording(sessionID: String) async throws -> String {
        guard let recording = activeRecordings.removeValue(forKey: sessionID) else {
            throw AmooError.commandFailed(
                command: "stopRecording",
                output: "No active recording with session ID: \(sessionID)"
            )
        }

        try await adb.stopRecording(serial: activeSerial)
        _ = try await adb.run(adbArgs() + ["pull", recording.remotePath, recording.localPath])
        // Best-effort cleanup; don't fail the call if the device-side rm fails.
        _ = try? await adb.run(adbArgs() + ["shell", "rm", recording.remotePath])
        return recording.localPath
    }

    // MARK: - Accessibility (delegate to companion)

    public func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await companion.findElements(selector)
    }

    public func findElements(_ selector: ElementSelector, appID: String?) async throws -> [ElementInfo] {
        try await companion.findElements(selector, appID: appID, candidateBundleIDs: [])
    }

    public func getViewHierarchy() async throws -> ViewNode {
        try await companion.getViewHierarchy(appID: nil, candidateBundleIDs: [])
    }

    public func getViewHierarchy(appID: String?) async throws -> ViewNode {
        try await companion.getViewHierarchy(appID: appID, candidateBundleIDs: [])
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
            if elements.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AmooError.timeout(operation: "waitForElementToDisappear", duration: timeout)
    }

    /// Android hosts permission dialogs and system chrome here.
    nonisolated public var systemUIAppID: String? {
        "com.android.systemui"
    }

    public func isKeyboardVisible() async throws -> Bool {
        try await companion.isKeyboardVisible()
    }

    public func currentApp() async throws -> CurrentApp {
        let info = try await companion.currentApp()
        return CurrentApp(bundleID: info.bundleID, targetBundleID: info.targetBundleID)
    }

    public func setTargetApp(bundleID: String?) async throws {
        try await companion.setTargetApp(bundleID: bundleID)
    }

    public func screenGeometry() async throws -> ScreenSize {
        let info = try await companion.screenInfo()
        return ScreenSize(
            widthPoints: info.widthPoints,
            heightPoints: info.heightPoints,
            widthPixels: info.widthPixels,
            heightPixels: info.heightPixels,
            scale: info.scale
        )
    }

    // MARK: - Configuration

    public func setPermission(_ change: PermissionChange) async throws {
        if change.granted {
            try await adb.grantPermission(serial: activeSerial, appID: change.appID, permission: change.permission)
        } else {
            try await adb.revokePermission(serial: activeSerial, appID: change.appID, permission: change.permission)
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
}
