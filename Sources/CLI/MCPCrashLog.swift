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

    private struct SignalRecord {
        var message: UnsafePointer<CChar>?
        var count: Int = 0
        var previous: (@convention(c) (Int32) -> Void)?
    }

    // Allocated and filled before handler installation; never freed while handlers are installed.
    nonisolated(unsafe) private static var records: UnsafeMutablePointer<SignalRecord>?
    nonisolated(unsafe) private static var logDescriptor: Int32 = -1

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
        guard records == nil else { return }
        let prepared = UnsafeMutablePointer<SignalRecord>.allocate(capacity: 64)
        prepared.initialize(repeating: SignalRecord(), count: 64)
        logDescriptor = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        for number in signals {
            let message = "amoo mcp serve: fatal signal \(number) in pid \(getpid())\n"
            prepared[Int(number)].message = strdup(message).map { UnsafePointer($0) }
            prepared[Int(number)].count = message.utf8.count
        }
        records = prepared
        for number in signals {
            prepared[Int(number)].previous = signal(number) { received in
                guard let records = Self.records, received >= 0, received < 64 else { return }
                let record = records[Int(received)]
                if let message = record.message {
                    _ = write(STDERR_FILENO, message, record.count)
                    if Self.logDescriptor >= 0 {
                        _ = write(Self.logDescriptor, message, record.count)
                    }
                }
                // Let the previously installed runtime/system handler produce its own report.
                signal(received, record.previous)
                raise(received)
            }
        }
    }
}
