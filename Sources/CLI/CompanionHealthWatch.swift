// SwiftFormat compact wrapping conflicts with parameter layout lint.
// swiftlint:disable multiline_parameters
/// Wait for consecutive failed bounded API probes, resetting after every successful probe.
/// Capability RPCs run independently of synchronous XCTest operations; a slow gesture is not a crash.
func waitForCompanionAPIUnavailable(
    pollInterval: Swift.Duration = .seconds(2), failureLimit: Int = 3,
    probe: @Sendable () async -> Bool
) async {
    precondition(pollInterval > .zero && failureLimit > 0)
    var failures = 0
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: pollInterval)
        } catch {
            return
        }
        failures = await probe() ? 0 : failures + 1
        if failures >= failureLimit {
            return
        }
    }
}

extension CompanionManager {
    static func watchOwnedRunner(ownsRunner: Bool, config: CompanionConfig?) async {
        guard ownsRunner, let config, !config.isPhysicalDevice else {
            await CompanionSignalWaiter.never()
            return
        }
        await waitForCompanionAPIUnavailable {
            await isCompanionReady(host: config.host, port: config.port)
        }
    }
}

// swiftlint:enable multiline_parameters
