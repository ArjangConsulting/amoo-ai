import AmooCore
@testable import CompanionProtocol
import GRPCCore
import Protos
import XCTest

final class AccessibilityInspectionClientTests: XCTestCase {
    func testVoiceOverRequestAndRestoredStateRoundTrip() async throws {
        let rpc = MockRPCClient()
        await rpc.stubInspection()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let result = try await client.inspectAccessibility(
            appID: "com.test", operation: "voiceOver", categories: [], steps: 3, direction: "backward"
        )
        let request = await rpc.inspection.request
        XCTAssertEqual(request?.appID, "com.test")
        XCTAssertEqual(request?.steps, 3)
        XCTAssertEqual(request?.direction, "backward")
        XCTAssertEqual(result.utterances, ["Year 2026, button"])
        XCTAssertEqual(result.originalVoiceOverEnabled, false)
        XCTAssertEqual(result.restoredVoiceOverEnabled, false)
    }

    func testMultiPhaseRequestUsesOneRPCAndPreservesBoundaries() async throws {
        let rpc = MockRPCClient()
        await rpc.stubInspection()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        _ = try await client.inspectVoiceOver(
            appID: "com.test",
            phases: [.init(steps: 3, direction: "forward"), .init(steps: 3, direction: "backward")]
        )
        let request = await rpc.inspection.request
        XCTAssertEqual(request?.phases.map(\.direction), ["forward", "backward"])
        XCTAssertEqual(request?.phases.map(\.steps), [3, 3])
        let calls = await rpc.inspection.calls
        XCTAssertEqual(calls, 1)
    }

    func testOldCompanionCannotSilentlyIgnoreMultiPhaseRequest() async throws {
        let rpc = MockRPCClient()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let result = try await client.inspectVoiceOver(
            appID: "com.test",
            phases: [.init(steps: 3, direction: "forward"), .init(steps: 3, direction: "backward")]
        )
        XCTAssertEqual(result.status, "unsupported")
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertTrue(result.error?.contains("build_mode=rebuild") == true)
        let calls = await rpc.inspection.calls
        XCTAssertEqual(calls, 0)
    }

    func testSelectedPresencePreservesUnknownAndFalse() async throws {
        let rpc = MockRPCClient()
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let unknown = try await client.findElements(.init(), appID: nil, candidateBundleIDs: [])
        XCTAssertNil(unknown.first?.isSelected)
        await rpc.stubSelectedState(false)
        let known = try await client.findElements(.init(), appID: nil, candidateBundleIDs: [])
        XCTAssertEqual(known.first?.isSelected, false)
    }

    func testTraversalWithoutDurableRecoveryCapabilityIsRefused() async throws {
        let rpc = MockRPCClient()
        await rpc.stubInspection(recovery: false)
        let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
        let result = try await client.inspectVoiceOver(
            appID: "com.test",
            phases: [.init(steps: 1, direction: "forward")]
        )
        XCTAssertEqual(result.executionStatus, "unsupported")
        XCTAssertTrue(result.error?.contains("accessibility.voiceOverRecovery") == true)
        let calls = await rpc.inspection.calls
        XCTAssertEqual(calls, 0)
    }

    func testDeadlineCancellationAndCrashCannotClaimRestoration() async throws {
        for code in [RPCError.Code.deadlineExceeded, .cancelled, .unavailable] {
            let rpc = MockRPCClient()
            await rpc.stubInspection(error: RPCError(code: code, message: "Injected transport fault"))
            let client = GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
            let result = try await client.inspectVoiceOver(
                appID: "com.test",
                phases: [.init(steps: 2, direction: "forward")]
            )
            XCTAssertEqual(result.executionStatus, "failed")
            XCTAssertEqual(result.verdict, "notAssessed")
            XCTAssertEqual(result.cleanupStatus, "unknown")
            XCTAssertTrue(result.evaluatedChecks.isEmpty)
            XCTAssertEqual(result.notEvaluatedReasons.keys.sorted(), ["traversal.phase.0"])
        }
    }
}

extension MockRPCClient {
    func getCapabilities(_ request: Amoo_CapabilitiesRequest) async throws
        -> Amoo_CapabilitiesResponse {
        _ = request

        var capability = Amoo_CapabilityDescriptor()
        capability.key = "query.findElements"
        capability.tier = .required
        capability.supported = true

        var response = Amoo_CapabilitiesResponse()
        response.capabilities = [capability] + inspectionCapabilities()
        return response
    }

    func inspectionCapabilities() -> [Amoo_CapabilityDescriptor] {
        inspection.capabilityKeys.map {
            var descriptor = Amoo_CapabilityDescriptor()
            descriptor.key = $0
            descriptor.tier = .optional
            descriptor.supported = true
            return descriptor
        }
    }

    struct InspectionStub: Sendable {
        var request: Amoo_AccessibilityInspectionRequest?
        var response = Amoo_AccessibilityInspectionResponse()
        var selectedState: Bool?
        var capabilityKeys: [String] = []
        var calls = 0
        var error: RPCError?
    }

    func stubInspection(recovery: Bool = true, error: RPCError? = nil) {
        inspection.capabilityKeys = ["accessibility.voiceOverTraversal", "accessibility.voiceOverPhases"]
        if recovery {
            inspection.capabilityKeys.append("accessibility.voiceOverRecovery")
        }
        inspection.error = error
        inspection.response.status = "observed"
        inspection.response.provider = "appleVoiceOver"
        inspection.response.utterances = ["Year 2026, button"]
        inspection.response.originalVoiceoverEnabled = false
        inspection.response.restoredVoiceoverEnabled = false
    }

    func stubSelectedState(_ value: Bool) {
        inspection.selectedState = value
    }

    func inspectAccessibility(_ request: Amoo_AccessibilityInspectionRequest) async throws
        -> Amoo_AccessibilityInspectionResponse {
        inspection.calls += 1
        inspection.request = request
        if let error = inspection.error {
            throw error
        }
        return inspection.response
    }
}
