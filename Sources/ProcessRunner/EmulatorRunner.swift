import AmooCore
import Foundation
import SwiftyShell

public protocol EmulatorRunning: Sendable {
    func launch(avdName: String, port: Int) async throws
}

public struct EmulatorRunner: EmulatorRunning {
    /// Unused now that launch spawns a fully detached process, but kept so existing call
    /// sites (`EmulatorRunner(context:)`) don't need to change.
    public init(context: ShellContext = .init()) {}

    /// Launches the emulator fully detached — its own session, not a managed `SpawnedProcess`.
    ///
    /// A `SpawnedProcess` handle signals its child when deinitialized, so the launcher died
    /// within ~8s (129ddef). A plain `Process` fixed that but still left the emulator in amoo's
    /// process group, so a harness tearing down that group killed it after boot.
    /// `DetachedProcess` starts it in a new session instead. Output goes to
    /// `$TMPDIR/amoo-emulator-<port>.log` for post-mortems.
    public func launch(avdName: String, port: Int) async throws {
        try DetachedProcess.spawn(
            Self.launchArguments(avdName: avdName, port: port),
            logPath: NSTemporaryDirectory() + "amoo-emulator-\(port).log"
        )
    }

    public static func launchArguments(avdName: String, port: Int) -> [String] {
        ["emulator", "-avd", avdName, "-port", String(port), "-no-snapshot-save"]
    }
}
