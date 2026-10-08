import Foundation

/// Avoid rehashing an unchanged executable on every MCP response. Atomic replacement changes file identity.
final class BinaryFingerprintCache: @unchecked Sendable {
    static let shared = BinaryFingerprintCache()
    private let lock = NSLock()
    private var entries: [String: (signature: String, hash: String)] = [:]

    func hash(path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let keys: [FileAttributeKey] = [.systemFileNumber, .size, .modificationDate, .creationDate]
        let signature = keys.map { String(describing: attributes[$0]) }.joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[path], cached.signature == signature {
            return cached.hash
        }
        guard let hash = sha256Hex(ofRegularFile: path) else { return nil }
        entries[path] = (signature, hash)
        return hash
    }
}
