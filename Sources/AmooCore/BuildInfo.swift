import Foundation

/// Identity of the running amoo binary, captured once at process start.
///
/// Long-lived `amoo mcp serve` processes keep executing the code they were started with; a
/// rebuild replaces the file on disk but not the running image. Local builds all report the
/// last release-stamped `AmooVersion`, so the version alone cannot tell a stale server from a
/// fresh one — the executable's modification time and the checkout's HEAD can.
public struct AmooBuildInfo: Sendable, Codable, Equatable {
    public var version: String
    public var executablePath: String?
    /// The binary's mtime when this process started.
    public var binaryModifiedAt: Date?
    /// HEAD of the source checkout the binary lives in (`.build/…`), when there is one.
    public var sourceCommit: String?
    public var startedAt: Date
    public var pid: Int32

    public init(
        version: String,
        executablePath: String?,
        binaryModifiedAt: Date?,
        sourceCommit: String?,
        startedAt: Date,
        pid: Int32
    ) {
        self.version = version
        self.executablePath = executablePath
        self.binaryModifiedAt = binaryModifiedAt
        self.sourceCommit = sourceCommit
        self.startedAt = startedAt
        self.pid = pid
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
            sourceCommit: resolved.flatMap(checkoutHead(near:)),
            startedAt: now,
            pid: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// When the binary on disk was replaced after this process started, the new file's mtime.
    public func replacedBinaryDate() -> Date? {
        guard let executablePath, let launched = binaryModifiedAt,
              let onDisk = Self.modificationDate(path: executablePath),
              onDisk.timeIntervalSince(launched) > 1
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
