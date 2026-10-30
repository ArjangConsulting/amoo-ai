import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Who holds a device's session lock, written into the lock file by the holder so a refused
/// process (and `amoo doctor`) can name it. The kernel lock stays the source of truth: this record
/// only identifies the holder, and an empty or unreadable one means an older amoo or another tool.
struct DeviceAccessHolder: Codable, Equatable, Sendable {
    var pid: Int32
    /// Executable and subcommand words only (`amoo mcp serve`); never option values.
    var command: String
    var acquiredAt: Date

    /// Whether the recorded process still exists. A reused pid reads as alive, which is the safe
    /// direction: it only ever delays recovery.
    var isAlive: Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func current(now: Date = Date()) -> Self {
        let arguments = ProcessInfo.processInfo.arguments
        let executable = arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"
        let words = arguments.dropFirst().prefix { !$0.hasPrefix("-") }.prefix(2)
        return Self(
            pid: getpid(),
            command: ([executable] + words).joined(separator: " "),
            acquiredAt: now
        )
    }

    /// Reads the record from a lock file, or `nil` when there is none.
    static func read(path: String) -> Self? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        return try? decoder.decode(Self.self, from: data)
    }

    /// Writes the record through an open, locked descriptor.
    func write(to descriptor: Int32) {
        guard let data = try? Self.encoder.encode(self) else { return }
        _ = ftruncate(descriptor, 0)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = pwrite(descriptor, base, buffer.count, 0)
        }
    }

    static func clear(descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
    }

    /// The text a refused caller sees.
    func refusal(lockPath: String) -> String {
        let since = ISO8601DateFormatter().string(from: acquiredAt)
        if isAlive {
            return "pid \(pid) (\(command)) since \(since). End its session, or if it is a stale MCP server run "
                + "`amoo doctor --mcp-pid \(pid) --kill-stale`"
        }
        return "pid \(pid) (\(command)) since \(since), which is no longer running; a descendant still holds "
            + "\(lockPath)"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
