import AmooCore
import Foundation
import MobileDevices

extension DeviceRuntimeStore {
    static func normalizedID(_ id: String) -> String {
        id.hasPrefix("lease-") ? "runtime-" + id.dropFirst(6) : id
    }

    var accessDirectory: URL {
        legacyDirectory ?? directory
    }

    func accessFileURL(deviceID: String) -> URL {
        accessDirectory.appendingPathComponent(fileURL(deviceID: deviceID).lastPathComponent)
    }

    func migrateLegacyRecords() {
        guard let legacyDirectory else { return }
        let legacy = DeviceClaimStore(directory: legacyDirectory)
        for record in legacy.allIncludingExpired() {
            let lock: DeviceAccessLock
            do {
                lock = try DeviceAccessLock(deviceID: record.deviceID, store: self)
            } catch {
                logger.info(
                    "Deferring runtime migration while the device is in use",
                    metadata: ["runtime": "\(record.id)", "action": "migrate", "error": "\(error)"]
                )
                continue
            }
            defer { lock.release() }
            guard let data = try? Data(contentsOf: legacy.fileURL(deviceID: record.deviceID)),
                  let current = try? Self.decoder.decode(DeviceClaim.self, from: data), current.id == record.id
            else { continue }
            let runtime = Self.convert(current)
            do {
                if let existing = read(fileURL(deviceID: runtime.deviceID)) {
                    guard existing.id == runtime.id else { continue }
                } else if legacyDirectory == directory {
                    try replace(runtime)
                } else {
                    try publish(runtime)
                }
                let oldLog = legacy.logURL(claimID: record.id)
                if FileManager.default.fileExists(atPath: oldLog.path),
                   !FileManager.default.fileExists(atPath: logURL(runtimeID: runtime.id).path) {
                    try FileManager.default.moveItem(at: oldLog, to: logURL(runtimeID: runtime.id))
                }
                if legacyDirectory != directory {
                    try FileManager.default.removeItem(at: legacy.fileURL(deviceID: record.deviceID))
                }
                logger.info("Migrated device runtime", metadata: ["runtime": "\(runtime.id)"])
            } catch {
                logger.error(
                    "Device runtime migration failed",
                    metadata: ["runtime": "\(runtime.id)", "error": "\(error)"]
                )
            }
        }
    }

    static func convert(_ record: DeviceClaim) -> DeviceRuntime {
        var runtime = DeviceRuntime(
            id: normalizedID(record.id),
            platform: Platform(record.platform),
            deviceID: record.deviceID,
            deviceName: record.deviceName,
            port: record.port,
            companionPID: record.holderPID,
            bootedByRuntime: record.bootedByLease,
            appID: record.appID,
            owner: record.owner,
            createdAt: record.createdAt,
            expiresAt: record.expiresAt
        )
        runtime.state = record.port == nil ? .starting : .running
        return runtime
    }
}
