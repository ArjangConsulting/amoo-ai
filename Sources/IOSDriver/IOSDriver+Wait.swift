import AmooCore
import AmooLogging
import CompanionProtocol
import Foundation

public extension IOSDriver {
    func waitForElementToDisappear(_ selector: ElementSelector, timeout: Duration) async throws {
        let context = try await appQueryContext()
        do {
            try await companion.waitForElementToDisappear(
                selector,
                timeout: timeout,
                appID: context.appID,
                candidateBundleIDs: context.candidateBundleIDs
            )
            return
        } catch AmooError.notImplemented {
            AmooLogger.forType(Self.self).debug(
                "Companion cannot wait for absence; polling from the host",
                context: "action=waitForElementToDisappear state=host_polling"
            )
        }
        let deadline = Date().addingTimeInterval(Double(timeout.milliseconds) / 1000.0)
        while Date() < deadline {
            let elements = try await companion.findElements(
                selector,
                appID: context.appID,
                candidateBundleIDs: context.candidateBundleIDs
            )
            if elements.isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AmooError.timeout(operation: "waitForElementToDisappear", duration: timeout)
    }
}
