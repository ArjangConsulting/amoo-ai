#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Detects `xcodebuild` / `xctest` processes that this `amoo` process did not start, so a caller
/// about to install or launch an app can be warned that a concurrent build may race with — or
/// outright kill (`pkill -f xcodebuild` in someone else's wrapper) — the install.
///
/// Deliberately cheap: one `pgrep` invocation, no polling, and a probe failure is swallowed —
/// an advisory must never block the operation it annotates.
public struct ForeignBuildDetector: Sendable {
    private let processRunner: any ProcessRunner
    private let ownProcessIDs: Set<Int32>

    /// - Parameters:
    ///   - processRunner: how to run `pgrep`. Defaults to the real system runner.
    ///   - ownProcessIDs: PIDs to treat as "ours" and exclude from the result. Defaults to this
    ///     process's ancestry, so the `xctest` runner hosting `swift test` never flags itself.
    public init(
        processRunner: any ProcessRunner = SystemProcessRunner(),
        ownProcessIDs: Set<Int32> = ProcessAncestry.current()
    ) {
        self.processRunner = processRunner
        self.ownProcessIDs = ownProcessIDs
    }

    /// The advisory string attached to a `start_session` / `device_install_app` result when a
    /// foreign build is running.
    public static let contentionWarning =
        "another xcodebuild/xctest process is running that amoo did not start; "
            + "the install or launch may race with it or be killed if that build tears down"

    /// A detector that never reports anything, for callers (and tests) that want the check to be
    /// a no-op without threading an optional through every construction site.
    public static let disabled = Self(
        processRunner: NullProcessRunner(),
        ownProcessIDs: []
    )

    /// `"<pid> <command>"` lines for running `xcodebuild` / `xctest` processes not started by this
    /// `amoo` process. Empty when nothing foreign is running or the probe could not run.
    public func foreignBuildProcesses() async -> [String] {
        // `pgrep -f -l` matches (and prints) the full argument vector; the ERE alternation is what
        // pgrep uses by default on macOS. `-l` prints "<pid> <command>".
        guard
            let result = try? await processRunner.run(["pgrep", "-f", "-l", "xcodebuild|xctest"]),
            result.exitCode == 0
        else {
            return []
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard
                    let pidToken = line.split(separator: " ", maxSplits: 1).first,
                    let pid = Int32(pidToken)
                else {
                    return false
                }
                guard !ownProcessIDs.contains(pid) else { return false }
                // Guard against a pgrep build that treated the pattern as a fixed string.
                return line.contains("xcodebuild") || line.contains("xctest")
            }
    }

    /// `contentionWarning` when a foreign build is running, otherwise `nil`.
    public func contentionWarning() async -> String? {
        await foreignBuildProcesses().isEmpty ? nil : Self.contentionWarning
    }
}

/// A `ProcessRunner` that runs nothing and reports a non-zero exit — backs `ForeignBuildDetector.disabled`.
struct NullProcessRunner: ProcessRunner {
    func run(_: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 1, stdout: "", stderr: "")
    }
}

/// This process's PID and every ancestor PID up to (but not including) `launchd`.
public enum ProcessAncestry {
    public static func current(limit: Int = 64) -> Set<Int32> {
        var result: Set<Int32> = []
        #if canImport(Darwin)
        var pid = getpid()
        var hops = 0
        while pid > 1, hops < limit {
            result.insert(pid)
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
            hops += 1
        }
        #endif
        return result
    }

    #if canImport(Darwin)
    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
    #endif
}
