import AmooCore
import CompanionProtocol
import Foundation

extension DefaultSessionBootstrapper {
    func waitForScreenReady(driver: any PlatformDriver) async throws {
        let deadline = ContinuousClock.now + .seconds(screenStabilizationTimeoutSeconds)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                _ = try await OperationDeadline.read(until: deadline) { try await driver.getScreenContext() }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch { try await Task.sleep(until: min(deadline, .now + .milliseconds(300)), clock: .continuous) }
        }
    }

    func waitForCompanionReady(_ companion: any CompanionClient) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        var lastError: (any Error)?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let capabilities = try await OperationDeadline
                    .read(until: deadline) { try await companion.getCapabilities() }
                guard capabilities.contains(where: { $0.key == "protocol.amoo.v1" && $0.supported }) else {
                    throw BootstrapError.connectionFailed(
                        "Companion protocol is incompatible with this Amoo CLI. Update/reinstall the companion "
                            + "with `amoo companion install --platform ios` (or android), then restart the session."
                    )
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BootstrapError {
                throw error
            } catch {
                if error.localizedDescription.localizedCaseInsensitiveContains("rpc isn't implemented")
                    || error.localizedDescription.localizedCaseInsensitiveContains("unimplemented") {
                    throw BootstrapError.connectionFailed(
                        "The running companion does not implement the RPCs required by this Amoo CLI. "
                            + "Update/reinstall it with `amoo companion install --platform ios` (or android)."
                    )
                }
                lastError = error
                try await Task.sleep(until: min(deadline, .now + .milliseconds(300)), clock: .continuous)
            }
        }
        throw BootstrapError.connectionFailed(
            lastError?.localizedDescription ?? "Companion gRPC readiness timed out."
        )
    }
}
