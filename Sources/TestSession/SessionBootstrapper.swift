import AmooCore
import Foundation

/// Produces fully configured drivers for new sessions. Implemented in the CLI
/// layer so the MCP server stays decoupled from the build toolchain.
public protocol SessionBootstrapper: Sendable {
    /// Boot/select a device, ensure the companion is reachable, install + launch
    /// the app, and return a ready-to-use driver bound to that session.
    func bootstrap(
        appID: String,
        platform: Platform,
        deviceHint: String?,
        buildPath: String?,
        arguments: [String],
        environment: [String: String]
    ) async throws -> BootstrapResult

    /// Enumerate currently usable devices for the given platform (or all when nil).
    func listDevices(platform: Platform?) async throws -> [DeviceInfo]
}

public struct BootstrapResult: Sendable {
    public let driver: any PlatformDriver
    public let deviceID: String
    public let platform: Platform
    /// Releases per-session resources (e.g. the gRPC client connection).
    /// Does NOT tear down the companion process itself — that stays alive for reuse.
    public let cleanup: @Sendable () async -> Void

    public init(
        driver: any PlatformDriver,
        deviceID: String,
        platform: Platform,
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.driver = driver
        self.deviceID = deviceID
        self.platform = platform
        self.cleanup = cleanup
    }
}
