import AmooCore
import CommandContract
import CompanionProtocol
import IOSDriver
import MCPServer
import XCTest

/// The unlabeled-element path, end to end against a real companion.
///
/// This is the only place the companion's own filtering is exercised. `getInteractableElements`
/// once restricted itself to named elements, which silently disabled UX-001
/// (`MissingAccessibilityLabelRule`) — it selects on `label.isEmpty && id.isEmpty`, so an empty
/// feed made it report a clean screen. The rule's unit test kept passing throughout, because it
/// builds its own input. Only a test that drives the real companion can catch that class of
/// regression, so these run against the fixture app's deliberately unnamed close button.
extension CommandContractE2ETests {
    func testUnfilteredQueryReportsAnUnlabeledControl() async throws {
        let server = try makeServer()
        try await openUnlabeledFixture(on: server)

        let named = await server.execute(toolName: "find_elements", arguments: ["labeled_only": "true"])
        XCTAssertFalse(named.isError, named.content)
        XCTAssertFalse(named.content.contains("[unlabeled]"), "labeled_only=true must suppress them: \(named.content)")

        let all = await server.execute(toolName: "find_elements", arguments: [:])
        XCTAssertFalse(all.isError, all.content)
        XCTAssertTrue(
            all.content.contains("[unlabeled]"),
            "An unfiltered query must report the fixture's unnamed close button: \(all.content)"
        )
    }

    /// The point of reporting an unlabeled element is that its frame is actionable. Tapping the
    /// centre `find_elements` reports has to move the app's state, or the frame is decoration.
    func testUnlabeledControlIsTappableAtItsReportedCentre() async throws {
        let server = try makeServer()
        try await openUnlabeledFixture(on: server)

        let before = await server.execute(toolName: "find_elements", arguments: ["id": dismissCountID])
        XCTAssertFalse(before.isError, before.content)
        XCTAssertTrue(before.content.contains("Dismissed: 0"), before.content)

        let all = await server.execute(toolName: "find_elements", arguments: [:])
        guard let centre = unlabeledCentreNearestFixtureButtonSize(in: all.content) else {
            return XCTFail("No unlabeled element with a centre in: \(all.content)")
        }

        let tap = await server.execute(toolName: "tap", arguments: ["x": "\(centre.x)", "y": "\(centre.y)"])
        XCTAssertFalse(tap.isError, tap.content)

        let after = await waitForElement(on: server, id: dismissCountID, containsText: "Dismissed: 1")
        XCTAssertTrue(
            after.content.contains("Dismissed: 1"),
            "Tapping the reported centre did not reach the control: \(after.content)"
        )
    }

    /// The exact seam Codex caught: the audit must see the unlabeled control, not a clean screen.
    func testAccessibilityAuditReportsTheUnlabeledControl() async throws {
        let server = try makeServer()
        try await openUnlabeledFixture(on: server)

        let audit = await server.execute(
            toolName: "audit_accessibility",
            arguments: ["app_id": Self.fixtureAppID]
        )
        XCTAssertFalse(audit.isError, audit.content)
        XCTAssertTrue(
            audit.content.contains("UX-001"),
            "The audit must report the unlabeled control, not a clean screen: \(audit.content)"
        )
    }

    // MARK: - Helpers

    private var dismissCountID: String {
        "fixture-unlabeled-dismiss-count"
    }

    private func openUnlabeledFixture(on server: MCPServer) async throws {
        guard Self.platform == .ios else {
            throw XCTSkip(
                "The unlabeled fixture screen exists only in the iOS host app. The filtering this"
                    + " covers is iOS-specific too: UIAutomator2's flat query never dropped"
                    + " unlabeled nodes."
            )
        }

        let ready = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-unlabeled",
            launcherLabel: "Open Unlabeled",
            readyID: "fixture-unlabeled-screen"
        )
        XCTAssertFalse(ready.isError, ready.content)
    }

    /// Reads every `[unlabeled] <type> at (x,y) pts WxH` entry out of the rendered result and
    /// returns the centre of whichever is closest to the fixture button's known 44x44 size.
    ///
    /// The rendering sorts unlabeled entries smallest-first as a *display* heuristic — it makes
    /// the common case ("the small thing is the icon button") read well — but nothing guarantees
    /// this fixture has no smaller decoration, so a test asserting behaviour should not lean on
    /// display order. Matching the frame this fixture actually declares is the reliable target.
    private func unlabeledCentreNearestFixtureButtonSize(in content: String) -> (x: Int, y: Int)? {
        let fixtureButtonSpan: Double = 44

        let candidates: [(centre: (x: Int, y: Int), sizeDelta: Double)] = content
            .split(separator: "\n")
            .filter { $0.contains("[unlabeled]") }
            .compactMap { line -> ((x: Int, y: Int), Double)? in
                guard let parenOpen = line.firstIndex(of: "("),
                      let parenClose = line[parenOpen...].firstIndex(of: ")"),
                      let ptsRange = line.range(of: "pts "),
                      let xRange = line[ptsRange.upperBound...].range(of: "x")
                else { return nil }

                let centrePair = line[line.index(after: parenOpen) ..< parenClose].split(separator: ",")
                guard centrePair.count == 2,
                      let x = Int(centrePair[0]),
                      let y = Int(centrePair[1]),
                      let width = Double(line[ptsRange.upperBound ..< xRange.lowerBound]),
                      let height = Double(line[xRange.upperBound...].prefix { $0.isNumber })
                else { return nil }

                let delta = abs(width - fixtureButtonSpan) + abs(height - fixtureButtonSpan)
                return ((x, y), delta)
            }

        return candidates.min { $0.sizeDelta < $1.sizeDelta }?.centre
    }
}
