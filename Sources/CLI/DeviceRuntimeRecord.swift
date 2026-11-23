import AmooCore
import Foundation

/// Lifecycle metadata for a companion. Device access is coordinated separately by DeviceAccessLock.
struct DeviceRuntime: Codable, Equatable, Sendable {
    var id: String
    var platform: Platform
    /// Simulator UDID or adb serial.
    var deviceID: String
    var deviceName: String?
    /// A port the companion serves on for this device, if any.
    var port: Int?
    /// A long-lived process holding resources for this runtime (e.g. a companion server).
    var companionPID: Int32?
    /// Whether the runtime's process booted the device, so it may shut it down on release.
    var bootedByRuntime: Bool
    var appID: String?
    /// The app `amoo device device_launch_app` last launched on this runtime, and its environment
    /// with sensitive values masked. A credential profile is checked against it.
    var launchedAppID: String?
    var launchEnvironment: [String: String]?
    /// Free-form caller label shown to anyone refused.
    var owner: String?
    var createdAt: Date
    var expiresAt: Date
    /// The lease length the runtime was started with (`env up --ttl`). Every renewal pushes
    /// `expiresAt` out by this much, whichever command renews it. `nil` on records written before
    /// it was stored; those renew by the renewing store's TTL.
    var leaseSeconds: TimeInterval?
    var state: DeviceRuntimeState = .starting

    init(
        id: String,
        platform: Platform,
        deviceID: String,
        deviceName: String? = nil,
        port: Int? = nil,
        companionPID: Int32? = nil,
        bootedByRuntime: Bool = false,
        appID: String? = nil,
        owner: String? = nil,
        createdAt: Date,
        expiresAt: Date,
        leaseSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.platform = platform
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.port = port
        self.companionPID = companionPID
        self.bootedByRuntime = bootedByRuntime
        self.appID = appID
        self.owner = owner
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.leaseSeconds = leaseSeconds
    }

    func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

/// The observed lifecycle of a companion, independent of whether its app is installed.
enum DeviceRuntimeState: String, Codable, Sendable {
    case starting, running, unresponsive, stale, stopped
}

/// Permission to use a device with the presented runtime credential.
enum RuntimeAccess: Equatable, Sendable {
    case free
    case owned(DeviceRuntime)
    case claimedByOther(DeviceRuntime)
}
