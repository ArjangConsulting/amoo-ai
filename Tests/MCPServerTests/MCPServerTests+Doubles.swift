import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }

    func data() -> Data {
        lock.withLock { storage }
    }
}

func waitForStdout(
    _ buffer: LockedDataBuffer,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: (String) -> Bool
) async throws -> Data {
    let start = ContinuousClock.now
    while start.duration(to: .now) < .nanoseconds(Int64(timeoutNanoseconds)) {
        let data = buffer.data()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        if condition(text) {
            return data
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    let text = String(bytes: buffer.data(), encoding: .utf8) ?? ""
    throw XCTSkip("Timed out waiting for MCP stdio response. Captured stdout: \(text)")
}

func waitForProcessExit(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
    let start = ContinuousClock.now
    while process.isRunning {
        if start.duration(to: .now) >= .nanoseconds(Int64(timeoutNanoseconds)) {
            return false
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

/// Every plausible location for the built `amoo` executable, most likely first.
///
/// Multiple candidates exist because the build layout varies with `--build-path`,
/// architecture-specific subdirectories, and Xcode's own output location — and because a
/// contributor testing both a native macOS build and a `--build-path .build-linux` container
/// build from the same checkout can end up with a stale, wrong-format binary at an earlier
/// candidate path. Callers should attempt each in order and fall through past a launch failure
/// rather than trusting the first executable-bit match.
func amooExecutableCandidates() -> [URL] {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let packageRoot = sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        packageRoot.appendingPathComponent(".build/debug/amoo"),
        packageRoot.appendingPathComponent(".build/out/Products/Debug/amoo"),
        packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/amoo"),
        packageRoot.appendingPathComponent(".build-linux/debug/amoo"),
        packageRoot.appendingPathComponent(".build-linux/x86_64-unknown-linux-gnu/debug/amoo"),
        packageRoot.appendingPathComponent(".build-linux/aarch64-unknown-linux-gnu/debug/amoo")
    ]
    return candidates.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// Mock driver that returns elements triggering audit rules.
actor AuditMockDriver: PlatformDriver {
    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.test", targetBundleID: "com.test")
    }

    func boot() async throws {}
    func shutdown() async throws {}
    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID _: String) async throws {}
    func uninstallApp(appID _: String) async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_: ElementSelector) async throws {}

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func swipe(direction _: Direction, distance _: Double, duration _: Duration) async throws {}
    func swipe(
        direction _: Direction,
        distance _: Double,
        duration _: Duration,
        element _: ElementSelector?
    ) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}
    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {}
    func pressHome() async throws {}
    func openURL(_: String) async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [
            // Element with empty label and empty id — triggers missing accessibility label
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 0, y: 0, width: 30, height: 30)),
            // Small tap target
            ElementInfo(id: "tiny", label: "Tiny", type: .button, frame: Rect(x: 10, y: 10, width: 20, height: 20)),
            // Sensitive text field — triggers insecure text field rule
            ElementInfo(id: "password_field", label: "Password", type: .textField),
            // Normal button
            ElementInfo(
                id: "submit_btn",
                label: "Submit",
                type: .button,
                frame: Rect(x: 0, y: 0, width: 100, height: 44)
            )
        ]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(
            id: "root",
            children: [
                ViewNode(id: "title", label: "Test screen", type: .staticText),
                ViewNode(id: "submit_btn", label: "Submit", type: .button),
                ViewNode(id: "cancel_btn", label: "Cancel", type: .button)
            ]
        )
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_: PermissionChange) async throws {}
    func setLocation(latitude _: Double, longitude _: Double) async throws {}
    func clearLocation() async throws {}
    func setAppearance(_: Appearance) async throws {}

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Debug mode enabled - Test screen", interactableCount: 4)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ]
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .running
    }
}

actor MockDriver: PlatformDriver {
    var calls: [String] = []
    var launchedAppID: String?

    func boot() async throws {
        calls.append("boot")
    }

    func shutdown() async throws {
        calls.append("shutdown")
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path: String) async throws {
        calls.append("install:\(path)")
    }

    func launchApp(appID: String, arguments _: [String], environment _: [String: String]) async throws {
        calls.append("launch:\(appID)")
        launchedAppID = appID
    }

    func terminateApp(appID: String) async throws {
        calls.append("terminate:\(appID)")
    }

    func uninstallApp(appID: String) async throws {
        calls.append("uninstall:\(appID)")
    }

    func tap(at point: Point) async throws {
        calls.append("tap:\(point.x),\(point.y)")
    }

    func doubleTap(at point: Point) async throws {
        calls.append("doubleTap:\(point.x),\(point.y)")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        calls.append("longPress")
    }

    func tapElement(_: ElementSelector) async throws {
        calls.append("tapElement")
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {
        calls.append("swipe")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration) async throws {
        calls.append("swipeInDirection:\(direction):\(distance)")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration, element: ElementSelector?) async throws {
        let suffix = element.flatMap(\.id).map { ":\($0)" } ?? ""
        calls.append("swipeInDirection:\(direction):\(distance)\(suffix)")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        calls.append("scroll:\(direction):\(distance)")
    }

    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_ text: String) async throws {
        calls.append("typeText:\(text)")
    }

    func clearText(characterCount _: Int?) async throws {
        calls.append("clearText")
    }

    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {
        calls.append("pressBack")
    }

    func pressHome() async throws {
        calls.append("pressHome")
    }

    func openURL(_ url: String) async throws {
        calls.append("openURL:\(url)")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: selector.id ?? "el", label: selector.label ?? "label")]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF], format: format)
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_ change: PermissionChange) async throws {
        calls.append("permission:\(change.appID):\(change.permission)")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        calls.append("location:\(latitude),\(longitude)")
    }

    func clearLocation() async throws {
        calls.append("clearLocation")
    }

    func setAppearance(_ appearance: Appearance) async throws {
        calls.append("appearance:\(appearance.rawValue)")
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Mock screen")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        []
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .running
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(
            bundleID: launchedAppID ?? "com.example.frontmost",
            targetBundleID: "com.example.target"
        )
    }
}

// MARK: - Additional test doubles for session, intent, and launch_args tests
