import AmooCore
import AmooLogging
import Foundation
#if os(macOS)
import AppKit
import CoreServices
#endif

/// The Mac's app launching and Launch Services, behind a seam so tests never touch the desktop.
public protocol MacWorkspace: Sendable {
    /// Registers an app bundle with Launch Services so its bundle id resolves to it.
    func register(appAt url: URL) throws
    /// The app Launch Services resolves `bundleID` to, or nil when none is installed.
    func applicationURL(bundleID: String) -> URL?
    func launch(appAt url: URL, arguments: [String], environment: [String: String]) async throws
    /// Quits every running instance of `bundleID`, forcing any that has not quit within a few seconds.
    func terminate(bundleID: String) async throws
    func runningApps() -> [AppInfo]
    func open(_ url: URL) async throws
    /// Whether the login window covers the desktop. Behind it no app window is on screen, so every
    /// query finds nothing and screenshots show the lock screen.
    func isScreenLocked() -> Bool
}

/// `MacWorkspace` over `NSWorkspace` and Launch Services.
public struct SystemMacWorkspace: MacWorkspace {
    private static let logger = AmooLogger.forType(Self.self)
    /// How long a polite quit gets before the app is force-quit.
    static let quitGraceSeconds = 5.0

    public init() {}

    #if os(macOS)
    public func register(appAt url: URL) throws {
        let status = LSRegisterURL(url as CFURL, true)
        guard status == noErr else {
            throw AmooError.commandFailed(command: "LSRegisterURL \(url.path)", output: "OSStatus \(status)")
        }
    }

    public func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func launch(appAt url: URL, arguments: [String], environment: [String: String]) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.activates = true
        Self.logger.info("Launching Mac app", context: "feature=macos action=launch app=\(url.lastPathComponent)")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            Self.logger.info("Launched Mac app", context: "feature=macos action=launch app=\(url.lastPathComponent)")
        } catch {
            Self.logger.error(
                "Mac app launch failed",
                error: error,
                context: "feature=macos action=launch app=\(url.lastPathComponent)"
            )
            throw AmooError.commandFailed(command: "launch \(url.path)", output: error.localizedDescription)
        }
    }

    public func terminate(bundleID: String) async throws {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return }
        Self.logger.info(
            "Quitting Mac app",
            context: "feature=macos action=terminate app=\(bundleID) instances=\(running.count)"
        )
        running.forEach { $0.terminate() }
        if try await Self.waitUntilGone(bundleID, seconds: Self.quitGraceSeconds) {
            Self.logger.info("Quit Mac app", context: "feature=macos action=terminate app=\(bundleID) forced=false")
            return
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.forceTerminate() }
        guard try await Self.waitUntilGone(bundleID, seconds: Self.quitGraceSeconds) else {
            let error = AmooError.commandFailed(
                command: "quit \(bundleID)",
                output: "Still running after a force quit."
            )
            Self.logger.error(
                "Mac app did not quit",
                error: error,
                context: "feature=macos action=terminate app=\(bundleID)"
            )
            throw error
        }
        Self.logger.info("Quit Mac app", context: "feature=macos action=terminate app=\(bundleID) forced=true")
    }

    /// Polls the running instances rather than `NSRunningApplication.isTerminated`, which AppKit
    /// updates on the main run loop, one a command-line host such as `amoo mcp serve` never runs.
    /// Launching before the old instance is gone attached to the dying process and left no window.
    private static func waitUntilGone(_ bundleID: String, seconds: Double) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                app.bundleIdentifier.map { AppInfo(appID: $0, name: app.localizedName) }
            }
    }

    public func isScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    public func open(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        do {
            _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        } catch {
            throw AmooError.commandFailed(command: "open \(url.absoluteString)", output: error.localizedDescription)
        }
    }
    #else
    public func register(appAt _: URL) throws {
        throw Self.unavailable
    }

    public func applicationURL(bundleID _: String) -> URL? {
        nil
    }

    public func launch(appAt _: URL, arguments _: [String], environment _: [String: String]) async throws {
        throw Self.unavailable
    }

    public func terminate(bundleID _: String) async throws {
        throw Self.unavailable
    }

    public func runningApps() -> [AppInfo] {
        []
    }

    public func open(_: URL) async throws {
        throw Self.unavailable
    }

    public func isScreenLocked() -> Bool {
        false
    }

    private static let unavailable = AmooError.unsupportedCapability(
        key: "platform.macos",
        reason: "driving a Mac needs amoo running on that Mac"
    )
    #endif
}
