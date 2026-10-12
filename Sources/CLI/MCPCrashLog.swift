import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Records fatal signals (Swift runtime aborts, traps, segfaults) raised inside `amoo mcp serve`.
///
/// A Swift runtime failure such as `freed pointer was not the last allocation` kills the process
/// with SIGABRT, and the MCP client only sees "Connection closed". The handler writes one line to
/// stderr and to a crash log, then re-raises so the exit status and any system crash report are
/// unchanged. Only async-signal-safe calls (`open`/`write`/`close`/`signal`/`raise`) run inside it.
enum MCPCrashLog {
    private static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    /// Pre-built so the handler never allocates.
    nonisolated(unsafe) private static var logPath: UnsafeMutablePointer<CChar>?

    /// The file fatal signals are appended to. `AMOO_CRASH_LOG` overrides the default.
    static func defaultLogURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AMOO_CRASH_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/amoo")
        #else
        let base = FileManager.default.temporaryDirectory.appending(path: "amoo")
        #endif
        return base.appending(path: "mcp-serve-crash.log")
    }

    /// Installs the handlers. Safe to call once per process; failures to prepare the log
    /// directory leave the stderr line in place.
    static func install(logURL: URL = defaultLogURL()) {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        logPath = strdup(logURL.path)
        for number in signals {
            signal(number) { received in
                Self.report(signal: received)
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func report(signal number: Int32) {
        var message: [UInt8] = Array("amoo mcp serve: fatal signal ".utf8)
        appendDecimal(Int(number), to: &message)
        message += Array(" in pid ".utf8)
        appendDecimal(Int(getpid()), to: &message)
        message.append(0x0A)
        message.withUnsafeBytes { _ = write(STDERR_FILENO, $0.baseAddress, $0.count) }
        guard let path = logPath else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        message.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    private static func appendDecimal(_ value: Int, to buffer: inout [UInt8]) {
        var digits: [UInt8] = []
        var remaining = value < 0 ? -value : value
        repeat {
            digits.append(UInt8(48 + remaining % 10))
            remaining /= 10
        } while remaining > 0
        if value < 0 {
            buffer.append(0x2D)
        }
        buffer += digits.reversed()
    }
}
