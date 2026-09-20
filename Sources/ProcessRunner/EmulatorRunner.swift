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

    /// Launches the emulator as a fully detached `Process`, not through SwiftyShell's
    /// managed spawn+teardown lifecycle.
    ///
    /// A `SpawnedProcess` handle sends its configured `TeardownStrategy` signal the moment
    /// the handle is deinitialized — by design, so no spawned process ever leaks past its
    /// caller's lifetime. The emulator is the opposite: it must outlive this call, the
    /// session, and potentially this whole `amoo` process. Live repro against a real AVD
    /// showed the previous `.spawn(teardown: .interruptThenTerminate)` + registry-held-handle
    /// approach still killed the launcher process within ~8s of spawn — well before boot
    /// could ever complete — with AOSP's own orphan-reaper watchdog finishing off the
    /// orphaned qemu child ~20s later. A plain detached `Process` (mirroring
    /// `launchDetachedProcess` in the CLI's interactive device selector) has no such hook.
    public func launch(avdName: String, port: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["emulator", "-avd", avdName, "-port", String(port), "-no-snapshot-save"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw AmooError.commandFailed(
                command: "emulator -avd \(avdName) -port \(port)",
                output: error.localizedDescription
            )
        }
    }
}
