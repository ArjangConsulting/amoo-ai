import AmooCore
import Foundation
import Logging
import MobileCore
import MobileDevices
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One JSON file per device in a shared directory.
///
/// Reads never modify anything: an expired runtime reads as free but stays on disk until a caller
/// that is taking the device (``start(platform:deviceID:deviceName:owner:companionPID:now:)``,
/// ``reapExpired(now:)``) retires it under the device's ``DeviceAccessLock``, after running the
/// consumer's `reaper` for the old companion.
struct DeviceRuntimeStore: Sendable {
    static let defaultTTL: TimeInterval = 60 * 60

    let directory: URL
    let legacyDirectory: URL?
    let ttl: TimeInterval
    /// Stops what an expired runtime's process left running, before the runtime file is removed.
    /// Only the consumer knows what that is; `nil` leaves nothing to stop.
    let reaper: (@Sendable (DeviceRuntime) -> Bool)?
    let logger = Logger(label: "amoo.cli.DeviceRuntimeStore")

    init(
        directory: URL,
        legacyDirectory: URL? = nil,
        ttl: TimeInterval = Self.defaultTTL,
        reaper: (@Sendable (DeviceRuntime) -> Bool)? = nil
    ) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.ttl = ttl
        self.reaper = reaper
        migrateLegacyRecords()
    }

    /// `$AMOO_RUNTIME_DIR`, else `~/.amoo/runtimes`: the directory existing tools already coordinate through.
    static func sharedDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AMOO_RUNTIME_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".amoo/runtimes",
            isDirectory: true
        )
    }

    /// Active (unexpired) runtimes, oldest first.
    func all(now: Date = Date()) -> [DeviceRuntime] {
        stored().filter { !$0.isExpired(at: now) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Every readable runtime, including expired ones, for diagnostics.
    func allIncludingExpired() -> [DeviceRuntime] {
        stored().sorted { $0.createdAt < $1.createdAt }
    }

    func runtime(forDevice deviceID: String, now: Date = Date()) -> DeviceRuntime? {
        stored().first { $0.deviceID == deviceID && !$0.isExpired(at: now) }
    }

    func runtime(id: String, includingExpired: Bool = false, now: Date = Date()) -> DeviceRuntime? {
        (includingExpired ? allIncludingExpired() : all(now: now)).first { $0.id == Self.normalizedID(id) }
    }

    func access(deviceID: String, presenting runtimeID: String?, now: Date = Date()) -> RuntimeAccess {
        guard let runtime = runtime(forDevice: deviceID, now: now) else { return .free }
        return runtime.id == runtimeID.map(Self.normalizedID) ? .owned(runtime) : .claimedByOther(runtime)
    }

    /// Claims a device. Two processes racing for it cannot both win: the runtime file is published
    /// with an exclusive hard link, so readers only ever see a complete record.
    ///
    /// - Throws: ``MobileKitError/deviceClaimed(device:holder:)`` when someone else holds it.
    func start(
        platform: Platform,
        deviceID: String,
        deviceName: String? = nil,
        owner: String? = nil,
        companionPID: Int32? = nil,
        now: Date = Date()
    ) throws -> DeviceRuntime {
        let lock = try DeviceAccessLock(deviceID: deviceID, store: self)
        defer { lock.release() }
        reapIfExpired(deviceID: deviceID, now: now)
        let mutation = try DeviceAccessLock(deviceID: deviceID, store: self, runtimeRecord: true)
        defer { mutation.release() }
        if let existing = runtime(forDevice: deviceID, now: now) {
            throw DeviceAccessError.controlledByOther(existing)
        }
        // An expired record that survived reaping means its companion could not be stopped. Say so
        // instead of failing later with a bare "file exists".
        if let leftover = read(fileURL(deviceID: deviceID)) {
            throw MobileKitError.deviceClaimed(
                device: deviceID,
                holder: "expired runtime \(leftover.id) whose companion could not be stopped; "
                    + "run `amoo env down --device \(deviceID) --force` to clear it"
            )
        }
        let created = Self.storedPrecision(now)
        let runtime = DeviceRuntime(
            id: "runtime-" + UUID().uuidString.prefix(8).lowercased(),
            platform: platform,
            deviceID: deviceID,
            deviceName: deviceName,
            companionPID: companionPID,
            owner: owner,
            createdAt: created,
            expiresAt: Self.storedPrecision(now.addingTimeInterval(ttl))
        )
        try publish(runtime)
        logger.info("Started runtime", metadata: ["device": "\(deviceID)", "runtime": "\(runtime.id)"])
        return runtime
    }

    /// Persists changes to an owned runtime and pushes its expiry out by one TTL. Refuses to
    /// overwrite a runtime someone else now holds.
    @discardableResult
    func refresh(_ runtime: DeviceRuntime, now: Date = Date()) throws -> DeviceRuntime {
        let mutation = try DeviceAccessLock(deviceID: runtime.deviceID, store: self, runtimeRecord: true)
        defer { mutation.release() }
        guard read(fileURL(deviceID: runtime.deviceID))?.id == runtime.id else {
            throw MobileKitError.notFound("Runtime \(runtime.id) on \(runtime.deviceID) no longer exists")
        }
        var renewed = runtime
        renewed.expiresAt = Self.storedPrecision(now.addingTimeInterval(ttl))
        try replace(renewed)
        return renewed
    }

    /// Removes the runtime if it is still this one. Works after expiry, so an owner can clean up late.
    @discardableResult
    func stop(_ runtime: DeviceRuntime) -> Bool {
        let mutation: DeviceAccessLock
        do {
            mutation = try DeviceAccessLock(deviceID: runtime.deviceID, store: self, runtimeRecord: true)
        } catch {
            logger.error(
                "Could not lock runtime record",
                metadata: ["runtime": "\(runtime.id)", "action": "stop", "error": "\(error)"]
            )
            return false
        }
        defer { mutation.release() }
        guard read(fileURL(deviceID: runtime.deviceID))?.id == runtime.id else { return false }
        do { try FileManager.default.removeItem(at: fileURL(deviceID: runtime.deviceID)) } catch {
            logger.error(
                "Could not remove runtime record",
                metadata: ["runtime": "\(runtime.id)", "action": "stop", "error": "\(error)"]
            )
            return false
        }
        logger.info("Stopped runtime", metadata: ["device": "\(runtime.deviceID)", "runtime": "\(runtime.id)"])
        return true
    }

    /// Retires every expired runtime whose device no session is driving. Each device is re-read
    /// under its ``DeviceAccessLock``, so a runtime taken meanwhile is never removed.
    @discardableResult
    func reapExpired(now: Date = Date()) -> [DeviceRuntime] {
        stored().filter { $0.isExpired(at: now) }.compactMap { expired in
            guard let lock = try? DeviceAccessLock(deviceID: expired.deviceID, store: self) else { return nil }
            defer { lock.release() }
            return reapIfExpired(deviceID: expired.deviceID, now: now)
        }
    }

    /// Runs the reaper for the device's expired runtime and removes it. The caller must hold the
    /// device's ``DeviceAccessLock``.
    @discardableResult
    func reapIfExpired(deviceID: String, now: Date = Date()) -> DeviceRuntime? {
        guard let mutation = try? DeviceAccessLock(deviceID: deviceID, store: self, runtimeRecord: true)
        else { return nil }
        defer { mutation.release() }
        let url = fileURL(deviceID: deviceID)
        guard let runtime = read(url), runtime.isExpired(at: now) else { return nil }
        logger.info("Reaping expired runtime", metadata: ["device": "\(deviceID)", "runtime": "\(runtime.id)"])
        if let reaper, !reaper(runtime) {
            logger.error("Runtime cleanup failed; retaining record", metadata: ["runtime": "\(runtime.id)"])
            return nil
        }
        do { try FileManager.default.removeItem(at: url) } catch {
            logger.error(
                "Could not remove expired runtime record",
                metadata: ["runtime": "\(runtime.id)", "action": "reap", "error": "\(error)"]
            )
            return nil
        }
        return runtime
    }

    /// Log file for a runtime's long-lived companion process.
    func logURL(runtimeID: String) -> URL {
        directory.appendingPathComponent("\(runtimeID).log")
    }
}
