import AmooCore
import Foundation

/// Produces fully configured drivers for new sessions. Implemented in the CLI
/// layer so the MCP server stays decoupled from the build toolchain.
public protocol SessionBootstrapper: Sendable {
    /// Boot/select a device, ensure the companion is reachable, install + launch
    /// the app, and return a ready-to-use driver bound to that session.
    func bootstrap(_ request: SessionBootstrapRequest) async throws -> BootstrapResult

    /// Enumerate currently usable devices for the given platform (or all when nil).
    func listDevices(platform: Platform?) async throws -> [DeviceInfo]

    /// Like `listDevices(platform:)`, but when `includeOffline` is true also reports installed
    /// simulators/emulators that are not currently booted. Defaults to `listDevices(platform:)`.
    func listDevices(platform: Platform?, includeOffline: Bool) async throws -> [DeviceInfo]

    /// Boot the simulator/emulator matching `hint` (a UDID/serial, a name, or the class hints
    /// `"simulator"` / `"device"`), or resolve it if already running, and return its info.
    /// Defaults to throwing — only a bootstrapper wired to the build toolchain can do this.
    func bootDevice(hint: String, platform: Platform) async throws -> DeviceInfo
}

public extension SessionBootstrapper {
    func listDevices(platform: Platform?, includeOffline _: Bool) async throws -> [DeviceInfo] {
        try await listDevices(platform: platform)
    }

    func bootDevice(hint _: String, platform _: Platform) async throws -> DeviceInfo {
        throw SessionBootstrapError.deviceBootUnsupported
    }
}

public enum SessionBootstrapError: Error, CustomStringConvertible {
    /// The active bootstrapper cannot boot a device by hint (no build toolchain wired in).
    case deviceBootUnsupported

    public var description: String {
        switch self {
        case .deviceBootUnsupported:
            "This server cannot boot a device by hint; boot the simulator/emulator yourself first."
        }
    }
}

/// Groups the parameters needed to bootstrap a new test session.
public struct SessionBootstrapRequest: Sendable {
    public let appID: String
    public let platform: Platform
    public let deviceHint: String?
    public let buildPath: String?
    public let arguments: [String]
    public let environment: [String: String]

    public init(
        appID: String,
        platform: Platform,
        deviceHint: String? = nil,
        buildPath: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        self.appID = appID
        self.platform = platform
        self.deviceHint = deviceHint
        self.buildPath = buildPath
        self.arguments = arguments
        self.environment = environment
    }
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
