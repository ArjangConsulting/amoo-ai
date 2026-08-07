import Foundation
import MobileTestingCore

/// Host-side operations that differ between an iOS *simulator* and a *physical device*.
///
/// Everything the companion handles (taps, gestures, accessibility) is identical on both,
/// because it runs inside the app under XCUITest. What differs is what the *host* can do
/// from outside: simulators are driven by `simctl`, devices by `devicectl`, and the two
/// tools do not cover the same ground.
///
/// The one genuine capability gap is ``setPermission(device:change:)`` — `simctl privacy`
/// has no `devicectl` counterpart, so the physical-device backend rejects it rather than
/// silently doing nothing.
public protocol IOSHostBackend: Sendable {
    // Device lifecycle
    func boot(device: String) async throws
    func shutdown(device: String) async throws
    func deviceInfo(device: String) async throws -> DeviceInfo

    // App management
    func installApp(device: String, path: String) async throws
    func launchApp(
        device: String,
        appID: String,
        arguments: [String],
        environment: [String: String]
    ) async throws
    func terminateApp(device: String, appID: String) async throws
    func uninstallApp(device: String, appID: String) async throws
    func listApps(device: String) async throws -> [AppInfo]

    // Capture
    func screenshot(device: String, format: ImageFormat) async throws -> ScreenshotData
    func startRecording(device: String, outputPath: String) async throws -> Int32
    func stopRecording(pid: Int32) async throws

    /// File extension the backend's recorder writes. `simctl` produces QuickTime `.mov`;
    /// `devicectl` requires the destination to be `.mp4` and errors otherwise.
    var recordingFileExtension: String { get }

    // Configuration
    func setPermission(device: String, change: PermissionChange) async throws
    func setLocation(device: String, latitude: Double, longitude: Double) async throws
    func clearLocation(device: String) async throws
    func setAppearance(device: String, appearance: Appearance) async throws
    func openURL(device: String, url: String) async throws
}
