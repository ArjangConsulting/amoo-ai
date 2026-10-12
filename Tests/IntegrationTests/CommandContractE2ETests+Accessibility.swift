import AmooCore
import XCTest

extension CommandContractE2ETests {
    func testAccessibilityCapabilitiesOnOlderSDKBuilds() async throws {
        guard Self.platform == .ios else {
            throw XCTSkip("The older XCTest SDK fallback is iOS-specific")
        }

        let companion = try makeCompanion()
        defer { Task { await companion.shutdown() } }
        let capabilities = try await companion.getCapabilities()
        let audit = try XCTUnwrap(capabilities.first { $0.key == "accessibility.nativeAudit" })
        XCTAssertTrue(audit.supported, "Native audits must remain available on older companion builds")
        let traversal = try XCTUnwrap(capabilities.first { $0.key == "accessibility.voiceOverTraversal" })
        let phases = try XCTUnwrap(capabilities.first { $0.key == "accessibility.voiceOverPhases" })
        XCTAssertEqual(phases.supported, traversal.supported)
        guard !traversal.supported else { return }

        for key in [
            "accessibility.voiceOverTraversal", "accessibility.voiceOverPhases",
            "accessibility.voiceOverRecovery", "accessibility.authoredJourney.v1"
        ] {
            let capability = try XCTUnwrap(capabilities.first { $0.key == key })
            XCTAssertFalse(capability.supported, key)
            XCTAssertFalse(capability.reasonIfUnsupported?.isEmpty ?? true, key)
        }
        let report = try await companion.inspectAccessibility(
            appID: Self.fixtureAppID,
            operation: "voiceOver",
            categories: [],
            steps: 1,
            direction: "forward"
        )
        XCTAssertEqual(report.status, "unsupported")
        XCTAssertTrue(report.utterances.isEmpty)
        XCTAssertNil(report.originalVoiceOverEnabled)
        XCTAssertNil(report.restoredVoiceOverEnabled)
    }
}
