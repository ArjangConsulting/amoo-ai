// Keep compact versioned JSON fixtures legible.
import AmooCore
@testable import CompanionProtocol
import Foundation
import Protos
import XCTest

final class AccessibilityJourneyClientTests: XCTestCase {
    private var journey: AccessibilityJourney {
        .init(id: "journey", steps: [.init(
            id: "order",
            kind: .order,
            direction: "forward",
            speech: [.init(equals: "First")]
        )])
    }

    func testJourneyUsesOneNegotiatedRPCAndPreservesAuthoredCoverage() async throws {
        let rpc = MockRPCClient()
        await rpc.stubJourney()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let result = try await client.inspectAccessibilityJourney(appID: "com.test", journey: journey)
        XCTAssertEqual(result.verdict, "pass")
        XCTAssertEqual(result.cleanupStatus, "restored")
        let stub = await rpc.inspection
        XCTAssertEqual(stub.calls, 1)
        XCTAssertEqual(stub.request?.operation, "journey")
        XCTAssertEqual(try JSONDecoder().decode(
            AccessibilityJourney.self,
            from: Data((stub.request?.journeyJson ?? "").utf8)
        ), journey)
        XCTAssertEqual(result.journey?.checkpoints.first?.utterances, ["First"])
    }

    func testOldCompanionAndMismatchedResponseCannotPass() async throws {
        for seed in ["old", "missing", "wrongID", "duplicates", "changedSpecification"] {
            let rpc = MockRPCClient()
            await rpc.stubJourney(seed: seed)
            let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
            let result = try await client.inspectAccessibilityJourney(appID: "com.test", journey: journey)
            XCTAssertEqual(result.verdict, "notAssessed", seed)
            XCTAssertEqual(result.requestedChecks, journey.requestedChecks, seed)
            XCTAssertEqual(result.cleanupStatus, "unknown", seed)
            let calls = await rpc.inspection.calls
            XCTAssertEqual(calls, seed == "old" ? 0 : 1)
        }
    }
}

extension MockRPCClient {
    func stubJourney(seed: String = "clean") {
        stubInspection()
        if seed != "old" {
            inspection.capabilityKeys.append("accessibility.authoredJourney.v1")
        }
        inspection.response.provider = "authoredAccessibilityJourney"
        inspection.response.requestedChecks = ["order.order.0"]
        inspection.response.evaluatedChecks = ["order.order.0"]
        let check = #"""
        {"id":"order.order.0","checkpointID":"order","source":"voiceOverSpeech",
         "outcome":"pass","expected":"First","actual":"First","reason":"Match"}
        """#
        let checks = seed == "duplicates" ? "\(check),\(check)" : check
        let id = seed == "wrongID" ? "wrong" : "journey"
        let expectation = seed == "changedSpecification" ? "Different" : "First"
        inspection.response.journeyReportJson = seed == "missing" ? "" : """
        {"schemaVersion":1,"id":"\(id)","specification":{"schemaVersion":1,"id":"journey",
        "steps":[{"id":"order","kind":"order","direction":"forward","speech":[{"equals":"\(expectation)"}]}]},
        "checks":[\(checks)],
         "checkpoints":[{"id":"order","elements":[],"utterances":["First"]}]}
        """
    }
}
