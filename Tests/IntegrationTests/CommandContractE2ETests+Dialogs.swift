import AmooCore
import AmooTools
import XCTest

/// The fixture's sign-in form: a password field and a SwiftUI `.alert` that the submit button
/// brings up. A tap on an alert that is still animating in can be dropped while the dispatch reports
/// success, so these follow the documented recipe: wait for the screen to settle, then tap with an
/// expectation that proves the tap landed.
extension CommandContractE2ETests {
    func testAPasswordFieldTakesTextAndTheAlertAnswersAfterItSettles() async throws {
        try XCTSkipUnless(Self.platform == .ios, "The Android fixture has no sign-in screen.")
        let server = try makeServer()
        let ready = await openSignInFixture(on: server)
        guard !ready.isError else { return XCTFail(ready.content) }

        for (id, value) in [("fixture-sign-in-username", "user"), ("fixture-sign-in-password", "secret12")] {
            let set = await server.execute(toolName: "set_text", arguments: ["id": id, "value": value])
            XCTAssertFalse(set.isError, set.content)
        }
        let length = await server.execute(
            toolName: "assert_visible",
            arguments: ["id": "fixture-sign-in-password-length", "label": "Password length: 8", "timeout_ms": "5000"]
        )
        XCTAssertFalse(length.isError, length.content)

        for (button, status) in [("continue", "Signed in"), ("cancel", "Sign-in cancelled")] {
            let alertButton = "fixture-sign-in-alert-\(button)"
            let submit = await server.execute(
                toolName: "tap_element",
                arguments: ["id": "fixture-sign-in-submit", "expect_id": alertButton]
            )
            XCTAssertEqual(submit.structuredContent?.objectValue?["expected_effect_met"], .bool(true), submit.content)

            let settled = await server.execute(
                toolName: "take_screenshot",
                arguments: ["settle_timeout_ms": "1500", "return_image": "false"]
            )
            XCTAssertFalse(settled.isError, settled.content)
            // iOS reports each SwiftUI alert button twice with the same id, label and frame; the
            // caller names one of them, amoo never picks.
            let answer = await server.execute(
                toolName: "tap_element",
                arguments: ["id": alertButton, "first": "true", "expect_id": alertButton, "expect_absent": "true"]
            )
            XCTAssertEqual(answer.structuredContent?.objectValue?["expected_effect_met"], .bool(true), answer.content)

            let reached = await server.execute(
                toolName: "assert_visible",
                arguments: ["id": "fixture-sign-in-status", "label": status, "timeout_ms": "5000"]
            )
            XCTAssertFalse(reached.isError, reached.content)
        }
    }

    /// The sign-in launcher is the home list's last row, inside the touch area of the floating
    /// bottom toolbar, which takes a tap there even though the row is drawn above it. Scrolling the
    /// list up first puts the row clear of the toolbar.
    private func openSignInFixture(on server: ToolCatalog) async -> ToolResult {
        let home = await resetFixtureApp(on: server)
        guard !home.isError else { return home }
        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down"])
        guard !scroll.isError else { return scroll }
        let open = await server.execute(
            toolName: "tap_element",
            arguments: ["id": "fixture-open-sign-in", "expect_id": "fixture-sign-in-password"]
        )
        guard open.structuredContent?.objectValue?["expected_effect_met"] == .bool(true) else {
            return .error("The sign-in screen did not open: \(open.content)")
        }
        return open
    }
}
