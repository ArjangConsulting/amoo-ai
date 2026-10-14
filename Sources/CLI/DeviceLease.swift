import AmooCore
import Foundation
import MobileCore
import MobileDevices

// A lease is a MobileDevices `DeviceClaim` in the directory every tool coordinates through
// (`$AMOO_LEASE_DIR`, else `~/.amoo/leases`). `amoo env up` takes one and returns its `id`; later
// calls prove ownership with `--lease <id>` (or `AMOO_LEASE`). Leases expire after a TTL that every
// use renews, so a crashed caller does not hold a device forever. What Amoo adds on top: its
// user-facing errors, `--lease`/`AMOO_LEASE`, renew-on-use, and reaping the companion an expired
// lease left running (`reapExpiredLease`).

extension DeviceClaimStore {
    /// The shared lease directory, reaping expired leases' companions with ``reapExpiredLease(_:)``.
    init(ttl: TimeInterval = Self.defaultTTL) {
        self.init(directory: Self.sharedDirectory(), ttl: ttl, reaper: reapExpiredLease)
    }

    /// Takes the device, mapping a refusal to the lease that holds it.
    func acquire(
        platform: Platform,
        deviceID: String,
        deviceName: String?,
        owner: String?,
        now: Date = Date()
    ) throws -> DeviceClaim {
        do {
            return try acquire(
                platform: MobilePlatform(platform), deviceID: deviceID, deviceName: deviceName, owner: owner, now: now
            )
        } catch MobileKitError.deviceClaimed {
            if let holder = claim(forDevice: deviceID, now: now) {
                throw DeviceLeaseError.leasedByOther(holder)
            }
            throw MobileKitError.deviceClaimed(device: deviceID, holder: "another active session")
        }
    }
}

extension DeviceClaim {
    /// The lease's platform in Amoo's terms.
    var amooPlatform: Platform {
        Platform(platform)
    }

    /// `lease-1a2b3c4d by owner, expires <date>`, for refusal messages.
    var summary: String {
        let who = owner.map { " by \($0)" } ?? ""
        return "\(id)\(who), expires \(ISO8601DateFormatter().string(from: expiresAt))"
    }
}

extension MobilePlatform {
    init(_ platform: Platform) {
        switch platform {
        case .ios: self = .ios
        case .android: self = .android
        }
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

enum DeviceLeaseError: Error, CustomStringConvertible, Equatable {
    case leasedByOther(DeviceClaim)
    case unknownLease(String)
    case wrongPlatform(DeviceClaim, requested: Platform)

    var description: String {
        switch self {
        case let .leasedByOther(lease):
            "Device \(lease.deviceID) is leased (\(lease.summary)). Another session is driving it — "
                + "pick another device, or pass its --lease id if it is yours. `amoo env list` shows all leases."
        case let .unknownLease(id):
            "No active lease '\(id)'. It may have expired; run `amoo env up` again."
        case let .wrongPlatform(lease, requested):
            "Lease \(lease.id) is for \(lease.platform.rawValue), not \(requested.rawValue). "
                + "Pass --platform \(lease.platform.rawValue)."
        }
    }
}

/// The lease a CLI call presents: `--lease`, else `AMOO_LEASE`.
func presentedLease(flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    if let flag, !flag.isEmpty {
        return flag
    }
    return environment["AMOO_LEASE"].flatMap { $0.isEmpty ? nil : $0 }
}

/// Refuses a call against a device another session has leased; renews the caller's own lease.
func enforceLease(
    deviceID: String?,
    lease leaseID: String?,
    store: DeviceClaimStore = DeviceClaimStore()
) throws {
    guard let deviceID, deviceID != "booted" else { return }
    switch store.access(deviceID: deviceID, presenting: leaseID) {
    case .free:
        return
    case let .owned(lease):
        _ = try? store.renew(lease)
    case let .claimedByOther(lease):
        throw DeviceLeaseError.leasedByOther(lease)
    }
}
