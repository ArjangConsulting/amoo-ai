import AmooCore
import AmooLogging
import Foundation

public extension AndroidDriver {
    /// Wakes the display and reports a state that held across consecutive reads. A single awake
    /// read is not enough: after a posture change the display can doze again immediately, and a
    /// loaded host can make one `dumpsys` read miss its deadline while the display is awake.
    func wake() async throws -> ScreenPowerState {
        let logger = AmooLogger.forType(Self.self)
        logger.info("Waking display", context: "action=wake state=requested")
        do {
            let wakeCommand = adbArgs() + ["shell", "input", "keyevent", "KEYCODE_WAKEUP"]
            _ = try await adb.run(wakeCommand, timeoutSeconds: 2)
            let deadline = ContinuousClock.now + .seconds(10)
            var nextWakeKey = ContinuousClock.now + .seconds(2)
            var candidate: ScreenPowerState?
            repeat {
                try Task.checkCancellation()
                let observed = try await androidScreenState()
                if let observed, observed == .on || observed == .locked {
                    if observed == candidate {
                        logger.info("Display wake verified", context: "action=wake state=\(observed.rawValue)")
                        return observed
                    }
                    candidate = observed
                } else {
                    candidate = nil
                    if ContinuousClock.now >= nextWakeKey {
                        _ = try? await adb.run(wakeCommand, timeoutSeconds: 2)
                        nextWakeKey = ContinuousClock.now + .seconds(2)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            } while ContinuousClock.now < deadline
            throw AmooError.commandFailed(
                command: "device_wake",
                output: "Display did not stay awake across consecutive reads; wake is unverified."
            )
        } catch {
            logger.error("Display wake failed", error: error, context: "action=wake state=unverified")
            throw error
        }
    }
}

public extension AndroidDriver {
    /// Asks Android to dismiss the keyguard. `wm dismiss-keyguard` removes a swipe keyguard but only
    /// raises the credential prompt for a secure one, so a state that stays `locked` means a PIN,
    /// pattern or passphrase is required. This never types a credential or touches the prompt.
    func dismissKeyguard() async throws -> ScreenPowerState {
        let logger = AmooLogger.forType(Self.self)
        logger.info("Dismissing keyguard", context: "action=dismissKeyguard state=requested")
        do {
            let current = try await wake()
            guard current == .locked else { return current }
            _ = try await adb.run(adbArgs() + ["shell", "wm", "dismiss-keyguard"], timeoutSeconds: 3)
            let deadline = ContinuousClock.now + .seconds(4)
            var candidate: ScreenPowerState?
            var latest = ScreenPowerState.locked
            repeat {
                try Task.checkCancellation()
                if let observed = try await androidScreenState() {
                    latest = observed
                    if observed == .on, candidate == .on {
                        logger.info("Keyguard dismissed", context: "action=dismissKeyguard state=on")
                        return .on
                    }
                    candidate = observed
                }
                try await Task.sleep(for: .milliseconds(250))
            } while ContinuousClock.now < deadline
            logger.info(
                "Keyguard remains; credential required",
                context: "action=dismissKeyguard state=\(latest.rawValue)"
            )
            return latest
        } catch {
            logger.error("Keyguard dismissal failed", error: error, context: "action=dismissKeyguard state=unverified")
            throw error
        }
    }
}
