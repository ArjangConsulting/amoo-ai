import AmooCore
import Protos

public extension GRPCCompanionClient {
    /// Needs a companion that advertises `query.waitForElement.absent`: one that predates the
    /// `condition` field would read the request as a wait for presence and report the wrong answer.
    func waitForElementToDisappear(
        _ selector: ElementSelector,
        timeout: Duration,
        appID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async throws {
        let capabilities = try await getCapabilities()
        guard capabilities.contains(where: { $0.key == "query.waitForElement.absent" && $0.supported }) else {
            throw AmooError.notImplemented("waitForElementToDisappear")
        }
        let request = Self.waitRequest(
            selector, timeout: timeout, appID: appID, candidateBundleIDs: candidateBundleIDs, condition: .absent
        )
        let response = try await rpcClient.waitForElement(request)
        if !response.found {
            throw AmooError.timeout(operation: "waitForElementToDisappear", duration: timeout)
        }
    }
}
