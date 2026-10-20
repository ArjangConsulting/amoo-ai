import AmooCore
import Foundation
import MobileCore
import MobileDevices

extension DeviceRuntimeStore {
    /// The shared runtime directory, reaping expired runtimes' companions with ``reapExpiredRuntime(_:)``.
    ///
    /// Overriding `AMOO_RUNTIME_DIR` isolates the store: the previous lease directory is only read
    /// (and migrated) when no override is set or `AMOO_LEASE_DIR` names it explicitly.
    init(ttl: TimeInterval = Self.defaultTTL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        let isolated = environment["AMOO_RUNTIME_DIR"].map { !$0.isEmpty } ?? false
        let leaseOverride = environment["AMOO_LEASE_DIR"].map { !$0.isEmpty } ?? false
        self.init(
            directory: Self.sharedDirectory(environment: environment),
            legacyDirectory: isolated && !leaseOverride ? nil : DeviceClaimStore.sharedDirectory(),
            ttl: ttl,
            reaper: reapExpiredRuntime
        )
    }
}

extension DeviceRuntime {
    /// The runtime's platform in Amoo's terms.
    var amooPlatform: Platform {
        platform
    }

    /// `runtime-1a2b3c4d by owner, expires <date>`, for refusal messages.
    var summary: String {
        let who = owner.map { " by \($0)" } ?? ""
        return "\(id)\(who), expires \(ISO8601DateFormatter().string(from: expiresAt))"
    }
}

extension Platform {
    init(_ platform: MobilePlatform) {
        switch platform {
        case .ios: self = .ios
        case .android: self = .android
        }
    }
}

enum DeviceAccessError: Error, CustomStringConvertible, Equatable {
    case controlledByOther(DeviceRuntime)
    case unknownRuntime(String)
    case wrongPlatform(DeviceRuntime, requested: Platform)

    var description: String {
        switch self {
        case let .controlledByOther(runtime):
            "Device \(runtime.deviceID) is being controlled by another session (\(runtime.summary)). "
                + "Pick another device, or pass --runtime-id <id> if it is yours. `amoo env list` shows all runtimes."
        case let .unknownRuntime(id):
            "No active runtime '\(id)'. It may have expired; run `amoo env up` again."
        case let .wrongPlatform(runtime, requested):
            "Runtime \(runtime.id) is for \(runtime.platform.rawValue), not \(requested.rawValue). "
                + "Pass --platform \(runtime.platform.rawValue)."
        }
    }
}

/// The runtime a CLI call presents: `--runtime-id`, else `AMOO_RUNTIME_ID`.
func presentedRuntime(flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    if let flag, !flag.isEmpty {
        return flag
    }
    return environment["AMOO_RUNTIME_ID"].flatMap { $0.isEmpty ? nil : $0 }
}

/// Refuses a call against a device another session has controlled; renews the caller's own runtime.
func enforceDeviceAccess(
    deviceID: String?,
    runtime runtimeID: String?,
    store: DeviceRuntimeStore = DeviceRuntimeStore()
) throws {
    if let runtimeID, store.runtime(id: runtimeID) == nil {
        throw DeviceAccessError.unknownRuntime(runtimeID)
    }
    guard let deviceID, deviceID != "booted" else { return }
    switch store.access(deviceID: deviceID, presenting: runtimeID) {
    case .free:
        return
    case let .owned(runtime):
        _ = try? store.refresh(runtime)
    case let .claimedByOther(runtime):
        throw DeviceAccessError.controlledByOther(runtime)
    }
}
