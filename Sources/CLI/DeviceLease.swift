import AmooCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A claim on one simulator/emulator, so concurrent sessions stop driving each other's devices.
///
/// `amoo env up` takes one and returns its `id`; later calls prove ownership with `--lease <id>`
/// (or `AMOO_LEASE`). Leases expire after a TTL that every use renews, so a crashed caller does
/// not hold a device forever. One file per device under `~/.amoo/leases/`.
struct DeviceLease: Codable, Equatable {
    var id: String
    var platform: Platform
    /// Simulator UDID or adb serial.
    var deviceID: String
    var deviceName: String?
    /// Companion port, when `env up` started one.
    var port: Int?
    /// The detached `amoo companion start` holding the companion open.
    var holderPID: Int32?
    /// Whether `env up` booted the device (so `env down --shutdown` may stop it).
    var bootedByLease: Bool
    var appID: String?
    /// Free-form caller label (`--owner` / `AMOO_LEASE_OWNER`), shown to anyone refused.
    var owner: String?
    var createdAt: Date
    var expiresAt: Date

    func isExpired(at now: Date = Date()) -> Bool {
        now >= expiresAt
    }

    var summary: String {
        let who = owner.map { " by \($0)" } ?? ""
        return "\(id)\(who), expires \(ISO8601DateFormatter().string(from: expiresAt))"
    }
}

enum DeviceLeaseError: Error, CustomStringConvertible, Equatable {
    case leasedByOther(DeviceLease)
    case unknownLease(String)

    var description: String {
        switch self {
        case let .leasedByOther(lease):
            "Device \(lease.deviceID) is leased (\(lease.summary)). Another session is driving it — "
                + "pick another device, or pass its --lease id if it is yours. `amoo env list` shows all leases."
        case let .unknownLease(id):
            "No active lease '\(id)'. It may have expired; run `amoo env up` again."
        }
    }
}

/// What a caller holding `lease` may do with `deviceID`.
enum LeaseAccess: Equatable {
    case free
    case owned(DeviceLease)
    case leasedByOther(DeviceLease)
}

struct DeviceLeaseStore {
    static let defaultTTL: TimeInterval = 60 * 60

    let directory: URL
    let ttl: TimeInterval

    init(directory: URL = Self.defaultDirectory(), ttl: TimeInterval = Self.defaultTTL) {
        self.directory = directory
        self.ttl = ttl
    }

    /// `$AMOO_LEASE_DIR`, else `~/.amoo/leases`.
    static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AMOO_LEASE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".amoo/leases", isDirectory: true)
    }

    /// Active (unexpired) leases. Expired files are removed as they are found.
    func all(now: Date = Date()) -> [DeviceLease] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let lease = read(url) else { return nil }
            if lease.isExpired(at: now) {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
            return lease
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func lease(forDevice deviceID: String, now: Date = Date()) -> DeviceLease? {
        let url = fileURL(deviceID: deviceID)
        guard let lease = read(url) else { return nil }
        if lease.isExpired(at: now) {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return lease
    }

    func lease(id: String, now: Date = Date()) -> DeviceLease? {
        all(now: now).first { $0.id == id }
    }

    func access(deviceID: String, lease leaseID: String?, now: Date = Date()) -> LeaseAccess {
        guard let lease = lease(forDevice: deviceID, now: now) else { return .free }
        return lease.id == leaseID ? .owned(lease) : .leasedByOther(lease)
    }

    /// Takes the device atomically (`O_EXCL`), so two `env up`s racing for it cannot both win.
    func acquire(
        platform: Platform,
        deviceID: String,
        deviceName: String?,
        owner: String?,
        now: Date = Date()
    ) throws -> DeviceLease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = lease(forDevice: deviceID, now: now) {
            throw DeviceLeaseError.leasedByOther(existing)
        }
        let lease = DeviceLease(
            id: "lease-" + UUID().uuidString.prefix(8).lowercased(),
            platform: platform,
            deviceID: deviceID,
            deviceName: deviceName,
            port: nil,
            holderPID: nil,
            bootedByLease: false,
            appID: nil,
            owner: owner,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl)
        )
        let path = fileURL(deviceID: deviceID).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            if let winner = self.lease(forDevice: deviceID, now: now) {
                throw DeviceLeaseError.leasedByOther(winner)
            }
            throw AmooError.commandFailed(command: "lease", output: String(cString: strerror(errno)))
        }
        close(descriptor)
        try write(lease)
        return lease
    }

    /// Persists changes to an owned lease and pushes its expiry out by one TTL.
    @discardableResult
    func update(_ lease: DeviceLease, now: Date = Date()) throws -> DeviceLease {
        var renewed = lease
        renewed.expiresAt = now.addingTimeInterval(ttl)
        try write(renewed)
        return renewed
    }

    func release(_ lease: DeviceLease) {
        guard self.lease(forDevice: lease.deviceID)?.id == lease.id else { return }
        try? FileManager.default.removeItem(at: fileURL(deviceID: lease.deviceID))
    }

    /// Log file for the lease's detached companion holder.
    func logURL(leaseID: String) -> URL {
        directory.appendingPathComponent("\(leaseID).log")
    }

    // MARK: - Files

    func fileURL(deviceID: String) -> URL {
        let safe = deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    private func read(_ url: URL) -> DeviceLease? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? Self.decoder.decode(DeviceLease.self, from: data)
    }

    private func write(_ lease: DeviceLease) throws {
        try Self.encoder.encode(lease).write(to: fileURL(deviceID: lease.deviceID), options: .atomic)
    }

    /// ISO-8601 with fractional seconds, so a lease survives a write/read round trip unchanged.
    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter().date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: raw))
            }
            return date
        }
        return decoder
    }()
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
    store: DeviceLeaseStore = DeviceLeaseStore()
) throws {
    guard let deviceID, deviceID != "booted" else { return }
    switch store.access(deviceID: deviceID, lease: leaseID) {
    case .free:
        return
    case let .owned(lease):
        try? store.update(lease)
    case let .leasedByOther(lease):
        throw DeviceLeaseError.leasedByOther(lease)
    }
}
