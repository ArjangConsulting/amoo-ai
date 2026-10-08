import Crypto
import Foundation

/// Streaming SHA-256 backed by Swift Crypto on every supported host platform.
public struct SHA256Digest {
    private var digest = Crypto.SHA256()
    public init() {}
    public mutating func update(_ data: Data) {
        digest.update(data: data)
    }

    public mutating func finalizeHex() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Hex SHA-256 of `data`.
public func sha256Hex(_ data: Data) -> String {
    var digest = SHA256Digest()
    digest.update(data)
    return digest.finalizeHex()
}

/// Stream a regular file with a hard byte limit. Directories and symbolic links are rejected.
public func sha256Hex(ofRegularFile path: String, maximumBytes: Int = 512 * 1024 * 1024) -> String? {
    let url = URL(fileURLWithPath: path)
    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var digest = SHA256Digest()
    var bytes = 0
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            bytes += chunk.count
            guard bytes <= maximumBytes else { return nil }
            digest.update(chunk)
        }
        return digest.finalizeHex()
    } catch { return nil }
}

/// Hex SHA-256 of a file, or of a bundle directory's sorted relative paths and contents.
public func sha256Hex(ofPath path: String) -> String? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    guard isDirectory.boolValue else {
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).map(sha256Hex)
    }
    let root = URL(fileURLWithPath: path)
    let files = (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? []).sorted()
    var digest = SHA256Digest()
    for relative in files {
        let url = root.appendingPathComponent(relative)
        var childIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &childIsDirectory),
              !childIsDirectory.boolValue,
              let contents = try? Data(contentsOf: url)
        else { continue }
        digest.update(Data(relative.utf8))
        digest.update(contents)
    }
    return digest.finalizeHex()
}
