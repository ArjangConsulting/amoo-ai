#if os(macOS)
import AmooCore
import AmooLogging
import Foundation
import MobileCore
import MobileDevices
import SwiftyShell

/// Boots a simulator with a bounded wait and recovers one that does not come up.
///
/// A healthy simulator boots in well under a minute. One that is still not ready by then is wedged
/// (a stuck `launchd_sim`, a data migration that never ends), and waiting longer has never helped:
/// shutting it down and booting again does. Callers therefore get an answer within about two
/// attempts instead of a wait measured in minutes.
public enum SimulatorBootRecovery {
    /// The longest one attempt waits for `simctl bootstatus`.
    public static let attemptTimeout: Swift.Duration = .seconds(60)

    private static let logger = AmooLogger.forType(Self.self)

    public static func boot(
        _ udid: String,
        shell: ShellContext,
        timeout: Swift.Duration = attemptTimeout,
        attempts: Int = 2
    ) async throws {
        let manager = SimulatorManager(shell: shell)
        var attempt = 1
        while true {
            do {
                logger.info("Booting simulator", context: "action=boot attempt=\(attempt)")
                try await manager.boot(udid, timeout: timeout)
                logger.info("Simulator booted", context: "action=boot attempt=\(attempt)")
                return
            } catch {
                guard attempt < attempts, !Task.isCancelled, isRecoverable(error) else {
                    logger.error("Simulator boot failed", error: error, context: "action=boot attempt=\(attempt)")
                    throw error
                }
                attempt += 1
                logger.error(
                    "Simulator did not finish booting; restarting it",
                    error: error,
                    context: "action=boot_recovery attempt=\(attempt)"
                )
                await StartupProgress.report(
                    "Simulator did not finish booting; shutting it down and booting again"
                        + " (attempt \(attempt) of \(attempts))"
                )
                try? await manager.shutdown(udid, timeout: .seconds(30))
            }
        }
    }

    /// A wait that ran out, or a `bootstatus` that failed, is worth one restart. A `simctl boot` that
    /// was refused (unknown device, missing runtime) fails the same way every time.
    static func isRecoverable(_ error: any Error) -> Bool {
        switch error {
        case MobileKitError.timedOut:
            true
        case let MobileKitError.commandFailed(command, _, _):
            command.contains("bootstatus")
        default:
            false
        }
    }
}
#endif
