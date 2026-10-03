import AmooCore
import Foundation
import SwiftyShell
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An emulator process started by amoo, so a boot wait can notice it died instead of sleeping out
/// its whole timeout.
public struct EmulatorLaunch: Sendable, Equatable {
    public enum Liveness: Sendable, Equatable {
        case running
        /// `exitCode` is nil when the process is gone but was not our child (no status to reap).
        case exited(exitCode: Int32?)
    }

    public var pid: Int32
    public var logPath: String?

    public init(pid: Int32, logPath: String?) {
        self.pid = pid
        self.logPath = logPath
    }

    /// Non-blocking. A detached child that has exited stays a zombie until reaped, so `kill(pid, 0)`
    /// alone reports it alive; `waitpid(WNOHANG)` both detects and reaps it.
    public func liveness() -> Liveness {
        #if os(Windows)
        return .running
        #else
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            let exited = (status & 0x7F) == 0
            return .exited(exitCode: exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
        }
        if result == -1, errno == ECHILD {
            return kill(pid, 0) == 0 ? .running : .exited(exitCode: nil)
        }
        return .running
        #endif
    }

    /// The last `lines` lines of the emulator log, for an error message.
    public func logTail(lines: Int = 25) -> String {
        guard let logPath, let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}

public protocol EmulatorRunning: Sendable {
    func launch(avdName: String, port: Int) async throws
    /// Like `launch`, but returns a handle to the process when one is available.
    func launchProcess(avdName: String, port: Int) async throws -> EmulatorLaunch?
}

public extension EmulatorRunning {
    func launchProcess(avdName: String, port: Int) async throws -> EmulatorLaunch? {
        try await launch(avdName: avdName, port: port)
        return nil
    }
}

public struct EmulatorRunner: EmulatorRunning {
    private let context: ShellContext

    /// Creates an emulator launcher with an injectable execution context.
    public init(context: ShellContext = .init()) {
        self.context = context
    }

    /// Launches an independent session and appends output to `$TMPDIR/amoo-emulator-<port>.log`.
    public func launch(avdName: String, port: Int) async throws {
        _ = try await launchProcess(avdName: avdName, port: port)
    }

    public func launchProcess(avdName: String, port: Int) async throws -> EmulatorLaunch? {
        let log = NSTemporaryDirectory() + "amoo-emulator-\(port).log"
        let pid = try await DetachedProcess.spawn(
            Self.launchArguments(avdName: avdName, port: port),
            logPath: log,
            context: context
        )
        return EmulatorLaunch(pid: pid, logPath: log)
    }

    public static func launchArguments(avdName: String, port: Int) -> [String] {
        ["emulator", "-avd", avdName, "-port", String(port), "-no-snapshot-save"]
    }
}
