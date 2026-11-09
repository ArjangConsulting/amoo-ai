import AmooCore
@testable import CompanionProtocol
import Protos
import XCTest

final class WaitForAbsenceTests: XCTestCase {
    private static let absenceCapability = "query.waitForElement.absent"

    private func makeClient(_ rpcClient: MockRPCClient) -> GRPCCompanionClient {
        GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpcClient)
    }

    func testWaitingForPresenceLeavesTheConditionToTheDefault() async throws {
        let rpcClient = MockRPCClient()
        let client = makeClient(rpcClient)

        try await client.waitForElement(.init(id: "spinner"), timeout: Duration(milliseconds: 500))

        let request = await rpcClient.waitForElementRequest
        XCTAssertEqual(request?.condition, .present)
    }

    func testWaitingForAbsenceAsksTheCompanionToWaitForAbsence() async throws {
        let rpcClient = MockRPCClient()
        await rpcClient.advertise(Self.absenceCapability)
        let client = makeClient(rpcClient)

        try await client.waitForElementToDisappear(
            .init(id: "spinner"), timeout: Duration(milliseconds: 500), appID: "com.example", candidateBundleIDs: []
        )

        let request = await rpcClient.waitForElementRequest
        XCTAssertEqual(request?.condition, .absent)
        XCTAssertEqual(request?.selector.id, "spinner")
        XCTAssertEqual(request?.appID, "com.example")
    }

    func testAnElementThatNeverLeavesTimesOut() async throws {
        let rpcClient = MockRPCClient()
        await rpcClient.advertise(Self.absenceCapability)
        await rpcClient.setWaitFound(false)
        let client = makeClient(rpcClient)
        let timeout = Duration(milliseconds: 500)

        do {
            try await client.waitForElementToDisappear(
                .init(id: "spinner"), timeout: timeout, appID: nil, candidateBundleIDs: []
            )
            XCTFail("Expected a timeout")
        } catch let error as AmooError {
            XCTAssertEqual(error, .timeout(operation: "waitForElementToDisappear", duration: timeout))
        }
    }

    func testACompanionWithoutTheCapabilityIsNeverAskedToWaitForAbsence() async throws {
        let rpcClient = MockRPCClient()
        let client = makeClient(rpcClient)

        do {
            try await client.waitForElementToDisappear(
                .init(id: "spinner"), timeout: Duration(milliseconds: 500), appID: nil, candidateBundleIDs: []
            )
            XCTFail("Expected notImplemented")
        } catch let error as AmooError {
            XCTAssertEqual(error, .notImplemented("waitForElementToDisappear"))
        }

        let request = await rpcClient.waitForElementRequest
        XCTAssertNil(request, "an older companion would read the request as a wait for presence")
    }
}

extension MockRPCClient {
    func advertise(_ key: String) {
        inspection.capabilityKeys.append(key)
    }

    func setWaitFound(_ found: Bool) {
        waitForElementFound = found
    }
}
