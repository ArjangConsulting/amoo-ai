import AmooCore
import Foundation
import MobileCore
import ProcessRunner
import SwiftyShell

/// What `simctl boot` said, reduced to what `env up` must act on: nil means carry on to the
/// `bootstatus` wait, a message means fail now with simctl's own words.
func simulatorBootFailure(exitCode: Int32?, stderr: String?) -> String? {
    guard let exitCode, exitCode != 0 else { return nil }
    let text = (stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Racing another booter: "Unable to boot device in current state: Booted" is not a failure.
    if text.contains("current state: Booted") || text.contains("current state: Booting") {
        return nil
    }
    return text.isEmpty ? "simctl boot exited \(exitCode)" : text
}

func bootSimulator(udid: String, readyTimeoutSeconds: Int?) async throws {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    // Per attempt: a simulator that misses it is shut down and booted once more.
    let waitSeconds = readyTimeoutSeconds ?? 300
    do {
        try await SimulatorBootRecovery.boot(udid, shell: context, timeout: .seconds(waitSeconds))
    } catch let MobileKitError.commandFailed(command, exitCode, output)
        where command.last == udid && command.contains("boot") {
        // A missing runtime image ("The iOS 27.0 simulator runtime is not available") can never boot;
        // say so now rather than waiting on `bootstatus` and reporting a bogus timeout.
        let failure = simulatorBootFailure(exitCode: exitCode, stderr: output) ?? "simctl boot exited \(exitCode)"
        throw EnvError.noDevice("Simulator \(udid) could not boot: \(failure)")
    } catch let MobileKitError.commandFailed(_, _, output) {
        throw EnvError
            .noDevice(
                "Simulator \(udid) did not finish booting: \(output.isEmpty ? "simctl bootstatus failed" : output)"
            )
    } catch MobileKitError.timedOut {
        throw EnvError
            .noDevice("Simulator \(udid) did not finish booting: no `simctl bootstatus` result within \(waitSeconds)s,"
                + " also after a shutdown and a second boot")
    }
}
