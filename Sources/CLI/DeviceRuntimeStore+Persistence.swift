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

extension DeviceRuntimeStore {
    /// `<directory>/<sanitized device id>.json`. The sanitizing keeps letters, digits, `-` and `.`;
    /// it must not change, or tools stop finding each other's runtimes.
    func fileURL(deviceID: String) -> URL {
        let safe = deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// Dates are stored with millisecond precision; truncating up front makes a returned runtime
    /// equal to the one read back from disk.
    static func storedPrecision(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }

    static func ownerDescription(_ runtime: DeviceRuntime) -> String {
        let owner = runtime.owner.map { " (\($0))" } ?? ""
        return "\(runtime.id)\(owner), expires \(ISO8601DateFormatter().string(from: runtime.expiresAt))"
    }

    func stored() -> [DeviceRuntime] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let current = files.filter { $0.pathExtension == "json" }.compactMap(read)
        guard let legacyDirectory else { return current }
        let legacy = DeviceClaimStore(directory: legacyDirectory).allIncludingExpired().map(Self.convert)
        return current + legacy.filter { old in !current.contains { $0.deviceID == old.deviceID } }
    }

    func read(_ url: URL) -> DeviceRuntime? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? Self.decoder.decode(DeviceRuntime.self, from: data)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    /// Writes to a private temporary file, then hard-links it into place: `link` fails if the
    /// runtime file exists, so publication is exclusive and atomic.
    func publish(_ runtime: DeviceRuntime) throws {
        try ensureDirectory()
        let temporary = try writeTemporary(runtime)
        defer { unlink(temporary.path) }
        guard link(temporary.path, fileURL(deviceID: runtime.deviceID).path) == 0 else {
            let code = errno
            if code == EEXIST, let winner = read(fileURL(deviceID: runtime.deviceID)) {
                throw MobileKitError.deviceClaimed(device: runtime.deviceID, holder: Self.ownerDescription(winner))
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Atomically replaces an existing runtime file.
    func replace(_ runtime: DeviceRuntime) throws {
        try ensureDirectory()
        let temporary = try writeTemporary(runtime)
        guard rename(temporary.path, fileURL(deviceID: runtime.deviceID).path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func writeTemporary(_ runtime: DeviceRuntime) throws -> URL {
        let url = directory.appendingPathComponent(".\(runtime.id).\(UUID().uuidString).tmp")
        let data = try Self.encoder.encode(runtime)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else {
            throw POSIXError(.EIO)
        }
        return url
    }

    static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
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
