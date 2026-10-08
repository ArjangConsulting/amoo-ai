import Foundation

/// Identity of the running amoo binary, captured once at process start.
///
/// Long-lived `amoo mcp serve` processes keep executing the code they were started with; a
/// rebuild replaces the file on disk but not the running image. Local builds all report the
/// last release-stamped `AmooVersion`, so the version alone cannot tell a stale server from a
/// fresh one. The binary hash and compiled source stamp identify the launched build.
public struct AmooBuildInfo: Sendable, Codable, Equatable {
    public var version: String
    public var executablePath: String?
    /// The binary's mtime when this process started.
    public var binaryModifiedAt: Date?
    /// Source commit stamped during compilation, never the checkout's current runtime HEAD.
    public var sourceCommit: String?
    public var startedAt: Date
    public var pid: Int32
    public var binarySHA256: String?
    public var sourceFingerprint: String?
    public var sourceDirty: String?

    public init(
        version: String,
        executablePath: String?,
        binaryModifiedAt: Date?,
        sourceCommit: String?,
        startedAt: Date,
        pid: Int32,
        binarySHA256: String? = nil,
        sourceFingerprint: String? = nil,
        sourceDirty: String? = nil
    ) {
        self.version = version
        self.executablePath = executablePath
        self.binaryModifiedAt = binaryModifiedAt
        self.sourceCommit = sourceCommit
        self.startedAt = startedAt
        self.pid = pid
        self.binarySHA256 = binarySHA256
        self.sourceFingerprint = sourceFingerprint
        self.sourceDirty = sourceDirty
    }

    /// Captured on first access; touch it early (at startup) so it describes the launched image.
    public static let current = capture()

    public static func capture(
        executableURL: URL? = Bundle.main.executableURL,
        now: Date = Date()
    ) -> Self {
        let resolved = executableURL?.resolvingSymlinksInPath()
        return Self(
            version: AmooVersion.current,
            executablePath: resolved?.path,
            binaryModifiedAt: resolved.flatMap { modificationDate(path: $0.path) },
            sourceCommit: CompiledBuildProvenance.commit == "unknown" ? nil : CompiledBuildProvenance.commit,
            startedAt: now,
            pid: ProcessInfo.processInfo.processIdentifier,
            binarySHA256: resolved.flatMap { BinaryFingerprintCache.shared.hash(path: $0.path) },
            sourceFingerprint: CompiledBuildProvenance.sourceFingerprint,
            sourceDirty: CompiledBuildProvenance.dirty
        )
    }

    /// When the binary on disk was replaced after this process started, the new file's mtime.
    public func replacedBinaryDate() -> Date? {
        guard let executablePath, let launched = binaryModifiedAt,
              let onDisk = Self.modificationDate(path: executablePath),
              onDisk != launched || binarySHA256
              .map({ BinaryFingerprintCache.shared.hash(path: executablePath) != $0 }) == true
        else { return nil }
        return onDisk
    }

    /// A warning for callers when this process is running superseded code, else `nil`.
    public func stalenessWarning() -> String? {
        guard let replaced = replacedBinaryDate() else { return nil }
        let format = ISO8601DateFormatter()
        return "⚠️ Stale amoo: this process (pid \(pid), started \(format.string(from: startedAt))) runs a binary "
            + "that was rebuilt at \(format.string(from: replaced)) (\(executablePath ?? "?")). Fixes made since "
            + "are not active here — restart it (for MCP: reconnect/restart the amoo MCP server)."
    }

    static func modificationDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Walks up from the executable to a `.git` directory and resolves HEAD without spawning git.
    static func checkoutHead(near executable: URL) -> String? {
        var directory = executable.deletingLastPathComponent()
        for _ in 0 ..< 8 {
            let gitDir = directory.appendingPathComponent(".git")
            if let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
                return resolveHead(head.trimmingCharacters(in: .whitespacesAndNewlines), gitDir: gitDir)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static func resolveHead(_ head: String, gitDir: URL) -> String? {
        guard head.hasPrefix("ref: ") else { return String(head.prefix(12)) }
        let ref = String(head.dropFirst("ref: ".count))
        if let loose = try? String(contentsOf: gitDir.appendingPathComponent(ref), encoding: .utf8) {
            return String(loose.trimmingCharacters(in: .whitespacesAndNewlines).prefix(12))
        }
        let packed = (try? String(contentsOf: gitDir.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        for line in packed.split(whereSeparator: \.isNewline) where line.hasSuffix(" " + ref) {
            return String(line.prefix(12))
        }
        return nil
    }
}
