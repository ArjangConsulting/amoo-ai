#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import AmooCore
import Foundation

/// Detects `xcodebuild` / `xctest` processes that this `amoo` process did not start, so a caller
/// about to install or launch an app can be warned that a concurrent build may race with — or
/// outright kill (`pkill -f xcodebuild` in someone else's wrapper) — the install.
///
/// Deliberately cheap: one `pgrep` invocation, no polling, and a probe failure is swallowed —
/// an advisory must never block the operation it annotates.
public struct ForeignBuildDetector: Sendable {
    let processRunner: any ProcessRunner
    let ownProcessIDs: Set<Int32>

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

    /// Appears in every companion run's arguments: its `.xctestrun` and runner are named for it.
    static let companionMarker = "AmooCompanion"

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
                // A companion is amoo's own long-running `xcodebuild test-without-building`, held
                // by a separate `amoo companion start` process and so outside this ancestry. It is
                // running for the whole session, so counting it warned on every install.
                guard !line.contains(Self.companionMarker) else { return false }
                // Guard against a pgrep build that treated the pattern as a fixed string.
                return line.contains("xcodebuild") || line.contains("xctest")
            }
    }

    /// `contentionWarning` when a foreign build is running, otherwise `nil`.
    public func contentionWarning() async -> String? {
        await foreignBuildProcesses().isEmpty ? nil : Self.contentionWarning
    }
}

// MARK: - Device hijack detection

public extension ForeignBuildDetector {
    /// Runner processes that amoo did not start and that target `deviceID` — raw `xcodebuild test
    /// -destination id=<udid>` on iOS, a `am instrument` session (Gradle `connectedAndroidTest`)
    /// on Android. Leases only coordinate amoo users, so such a runner can take the foreground or
    /// reinstall the app under test while amoo's RPCs wait on a screen that no longer exists.
    func hijackingProcesses(platform: Platform, deviceID: String) async -> [String] {
        guard !deviceID.isEmpty, deviceID != "booted" else { return [] }
        switch platform {
        case .ios:
            guard let result = try? await processRunner.run(["/bin/ps", "-axo", "pid=,args="]),
                  result.exitCode == 0 else { return [] }
            return Self.parseIOSHijackers(result.stdout, udid: deviceID, ownProcessIDs: ownProcessIDs)
        case .android:
            guard let result = try? await processRunner.run(["adb", "-s", deviceID, "shell", "ps", "-A", "-o", "PID,ARGS"]),
                  result.exitCode == 0 else { return [] }
            return Self.parseAndroidHijackers(result.stdout)
        }
    }

    /// The user-facing error for `hijackingProcesses`, nil when there are none.
    func hijackMessage(platform: Platform, deviceID: String) async -> String? {
        let processes = await hijackingProcesses(platform: platform, deviceID: deviceID)
        guard !processes.isEmpty else { return nil }
        return "device hijacked: \(deviceID) is being driven by a test runner amoo did not start — "
            + processes.prefix(3).map { "[\($0)]" }.joined(separator: " ")
            + ". It can take the foreground or reinstall the app under test, so amoo's calls time out. "
            + "Leases only coordinate amoo users: stop that process or use another device."
    }

    static func parseIOSHijackers(_ psOutput: String, udid: String, ownProcessIDs: Set<Int32>) -> [String] {
        psOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let token = line.split(separator: " ", maxSplits: 1).first, let pid = Int32(token),
                      !ownProcessIDs.contains(pid) else { return false }
                return (line.contains("xcodebuild") || line.contains("xctest"))
                    && line.contains(udid) && !line.contains(companionMarker)
            }
    }

    /// `ps -A -o PID,ARGS` from the device: `am`/`cmd activity instrument` sessions that are not
    /// amoo's own companion runner.
    static func parseAndroidHijackers(_ psOutput: String) -> [String] {
        psOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                let instruments = line.contains("activity instrument") || line.contains("commands.am.Am instrument")
                    || line.contains("am instrument")
                return instruments && !line.contains("com.amoo.companion")
            }
    }
}

/// A `ProcessRunner` that runs nothing and reports a non-zero exit — backs `ForeignBuildDetector.disabled`.
struct NullProcessRunner: ProcessRunner {
    func run(_: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 1, stdout: "", stderr: "")
    }
}

/// This process's PID and every ancestor PID up to (but not including) `launchd` / `init`.
public enum ProcessAncestry {
    public static func current(limit: Int = 64) -> Set<Int32> {
        var result: Set<Int32> = []
        var pid = getpid()
        var hops = 0
        while pid > 1, hops < limit {
            result.insert(pid)
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
            hops += 1
        }
        return result
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
        #elseif os(Linux)
        // `/proc/<pid>/stat` is "pid (comm) state ppid …"; `comm` may contain spaces and
        // parentheses, so split on the fields that follow the final ')'.
        guard
            let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let lastParen = stat.lastIndex(of: ")")
        else {
            return nil
        }
        let fields = stat[stat.index(after: lastParen)...]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let ppid = pid_t(fields[1]), ppid > 0 else { return nil }
        return ppid
        #else
        return nil
        #endif
    }
}
