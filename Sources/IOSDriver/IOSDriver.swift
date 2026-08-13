import AmooCore
import CompanionProtocol
import Foundation
import ProcessRunner

public actor IOSDriver: PlatformDriver {
    private struct ActiveRecording {
        let pid: Int32
        let outputPath: String
    }

    private let companion: any CompanionClient
    private let backend: any IOSHostBackend
    private let deviceID: String
    private var activeRecordings: [String: ActiveRecording] = [:] // sessionID → recording
    private var currentAppID: String?

    /// Creates a driver for an iOS *simulator*.
    public init(
        companion: any CompanionClient,
        simctl: any SimctlRunning = SimctlRunner(),
        deviceID: String = "booted"
    ) {
        self.init(
            companion: companion,
            backend: SimulatorHostBackend(simctl: simctl),
            deviceID: deviceID
        )
    }

    /// Creates a driver over an explicit host backend.
    ///
    /// Use ``physicalDevice(companion:devicectl:deviceID:)`` for a real device; this
    /// initializer exists so callers can inject a custom or fake backend.
    public init(
        companion: any CompanionClient,
        backend: any IOSHostBackend,
        deviceID: String = "booted"
    ) {
        self.companion = companion
        self.backend = backend
        self.deviceID = deviceID
    }

    /// Creates a driver for a *physical* iOS device.
    ///
    /// `deviceID` must be a UDID, identifier, or device name that `devicectl` accepts —
    /// there is no `"booted"` equivalent for real hardware, so it is required.
    ///
    /// The companion still has to be reachable: unlike a simulator, a device does not
    /// share localhost with the host, so open a `USBTunneling` forward first and point
    /// `companion` at the resulting local port.
    public static func physicalDevice(
        companion: any CompanionClient,
        devicectl: any DeviceCtlRunning = DeviceCtlRunner(),
        deviceID: String
    ) -> IOSDriver {
        IOSDriver(
            companion: companion,
            backend: PhysicalDeviceHostBackend(devicectl: devicectl),
            deviceID: deviceID
        )
    }

    // MARK: - DeviceDriver

    public func boot() async throws {
        try await backend.boot(device: deviceID)
    }

    public func shutdown() async throws {
        try await backend.shutdown(device: deviceID)
    }

    public func deviceInfo() async throws -> DeviceInfo {
        try await backend.deviceInfo(device: deviceID)
    }

    // MARK: - App Management

    public func installApp(path: String) async throws {
        try await backend.installApp(device: deviceID, path: path)
    }

    public func launchApp(
        appID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws {
        try await backend.launchApp(
            device: deviceID,
            appID: appID,
            arguments: arguments,
            environment: environment
        )
        currentAppID = appID
    }

    public func terminateApp(appID: String) async throws {
        try await backend.terminateApp(device: deviceID, appID: appID)
    }

    public func uninstallApp(appID: String) async throws {
        try await backend.uninstallApp(device: deviceID, appID: appID)
    }

    public func listApps() async throws -> [AppInfo] {
        try await backend.listApps(device: deviceID)
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

    // MARK: - Navigation Actions

    public func pressBack() async throws {
        try await companion.pressBack()
    }

    public func pressHome() async throws {
        try await companion.pressHome()
        currentAppID = nil
    }

    public func openURL(_ url: String) async throws {
        try await backend.openURL(device: deviceID, url: url)
    }

    // MARK: - Screen Capture

    public func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
        // Prefer companion screenshot (XCUIScreen) — simctl screenshot can time out when XCUITest is active
        do {
            return try await companion.takeScreenshot()
        } catch {
            // Fall back to the host backend if companion doesn't support screenshots
            return try await backend.screenshot(device: deviceID, format: format)
        }
    }

    public func startRecording() async throws -> RecordingSession {
        guard activeRecordings.isEmpty else {
            throw AmooError.commandFailed(
                command: "startRecording",
                output: "Only one active iOS recording is supported per driver."
            )
        }

        let sessionID = UUID().uuidString
        // The container format is backend-specific: simctl writes .mov, devicectl demands .mp4.
        let outputPath = NSTemporaryDirectory()
            + "recording_\(sessionID).\(backend.recordingFileExtension)"
        let pid = try await backend.startRecording(device: deviceID, outputPath: outputPath)
        activeRecordings[sessionID] = ActiveRecording(pid: pid, outputPath: outputPath)
        return RecordingSession(id: sessionID, deviceID: deviceID)
    }

    public func stopRecording(sessionID: String) async throws -> String {
        guard let recording = activeRecordings.removeValue(forKey: sessionID) else {
            throw AmooError.commandFailed(
                command: "stopRecording",
                output: "No active recording with session ID: \(sessionID)"
            )
        }

        try await backend.stopRecording(pid: recording.pid)
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
            if elements.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AmooError.timeout(operation: "waitForElementToDisappear", duration: timeout)
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

    // MARK: - Configuration

    public func setPermission(_ change: PermissionChange) async throws {
        try await backend.setPermission(device: deviceID, change: change)
    }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        try await backend.setLocation(device: deviceID, latitude: latitude, longitude: longitude)
    }

    public func clearLocation() async throws {
        try await backend.clearLocation(device: deviceID)
    }

    public func setAppearance(_ appearance: Appearance) async throws {
        try await backend.setAppearance(device: deviceID, appearance: appearance)
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

// MARK: - Helpers

extension IOSDriver {
    private func appQueryContext() async throws -> (appID: String?, candidateBundleIDs: [String]) {
        if let currentAppID {
            return (currentAppID, [])
        }

        return (nil, [])
    }
}
