import Foundation
import MobileTestingCore

/// A managed, app-scoped testing session. Holds the driver bound to this
/// session and records every tool invocation. Closing the session terminates
/// the app under test and releases the gRPC connection — but leaves the
/// companion process running for reuse.
public actor TestSession: Sendable {
    public nonisolated let id: String
    public nonisolated let appID: String
    public nonisolated let deviceID: String
    public nonisolated let platform: Platform
    public nonisolated let startedAt: Date
    public nonisolated let driver: any PlatformDriver

    public private(set) var endedAt: Date?
    public private(set) var actions: [SessionAction] = []
    public private(set) var isActive: Bool = true

    private let cleanup: @Sendable () async -> Void

    public init(
        id: String,
        appID: String,
        deviceID: String,
        platform: Platform,
        driver: any PlatformDriver,
        startedAt: Date = Date(),
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.appID = appID
        self.deviceID = deviceID
        self.platform = platform
        self.driver = driver
        self.startedAt = startedAt
        self.cleanup = cleanup
    }

    public func record(_ action: SessionAction) {
        guard isActive else { return }
        actions.append(action)
    }

    /// Terminates the app under test (best-effort) and releases the gRPC
    /// connection. Safe to call multiple times.
    public func close() async {
        guard isActive else { return }
        isActive = false
        endedAt = Date()
        try? await driver.terminateApp(appID: appID)
        await cleanup()
    }
}
