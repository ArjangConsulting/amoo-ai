import AmooCore
@testable import CompanionProtocol
import Foundation
import XCTest

/// Exercises the in-memory companion client — the stub `GRPCCompanionClient(connection:)`
/// builds when no live transport is wanted.
///
/// It is a shipped public path used for offline development and as a stand-in in tests, so
/// its behaviour is part of the contract: every action must succeed rather than throw, and
/// the query methods must return well-formed placeholder data rather than empty values that
/// would mask a wiring mistake in a caller.
final class InMemoryCompanionClientTests: XCTestCase {
    private func makeClient() -> GRPCCompanionClient {
        GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087))
    }

    // MARK: - Session

    func testSessionLifecycleSucceeds() async throws {
        let client = makeClient()

        try await client.startSession()
        let capabilities = try await client.getCapabilities()
        try await client.endSession()

        XCTAssertFalse(capabilities.isEmpty, "stub should advertise a capability set")
    }

    // MARK: - Actions

    func testEveryActionCompletesWithoutThrowing() async throws {
        let client = makeClient()
        let origin = Point(x: 10, y: 20)
        let destination = Point(x: 110, y: 220)

        // The stub reports success for all actions; if any started throwing, callers
        // written against it would break in ways that look like real device failures.
        try await client.tap(at: origin)
        try await client.doubleTap(at: origin)
        try await client.longPress(at: origin, duration: Duration(milliseconds: 300))
        try await client.tapElement(.init(id: "login"), appID: nil, candidateBundleIDs: [])
        try await client.swipe(from: origin, to: destination, duration: Duration(milliseconds: 200))
        try await client.swipeInDirection(.left, distance: 100, duration: Duration(milliseconds: 200), element: nil)
        try await client.scroll(direction: .down, distance: 250)
        try await client.drag(
            from: origin,
            to: destination,
            duration: Duration(milliseconds: 200),
            holdDuration: Duration(milliseconds: 500)
        )
        try await client.typeText("hello")
        try await client.clearText(characterCount: 3)
        try await client.pressBack()
        try await client.pressHome()
    }

    // MARK: - Queries

    func testQueriesReturnWellFormedPlaceholders() async throws {
        let client = makeClient()

        let elements = try await client.findElements(.init(id: "login"), appID: nil, candidateBundleIDs: [])
        let hierarchy = try await client.getViewHierarchy(appID: nil, candidateBundleIDs: [])
        let keyboardVisible = try await client.isKeyboardVisible()
        let screenshot = try await client.takeScreenshot()

        XCTAssertFalse(elements.isEmpty)
        XCTAssertFalse(hierarchy.id.isEmpty)
        // The stub reports no keyboard, so a caller that gates on this takes the
        // "keyboard hidden" branch by default rather than a misleading "visible".
        XCTAssertFalse(keyboardVisible)
        // A screenshot with no bytes would let an encoding bug pass unnoticed downstream.
        XCTAssertFalse(screenshot.bytes.isEmpty)
        XCTAssertEqual(screenshot.format, .png)
    }

    func testWaitForElementResolvesImmediately() async throws {
        let client = makeClient()

        try await client.waitForElement(
            .init(label: "Continue"),
            timeout: Duration(milliseconds: 500),
            appID: nil,
            candidateBundleIDs: []
        )
    }

    // MARK: - AI Context

    func testAIContextMethodsReturnData() async throws {
        let client = makeClient()

        let context = try await client.getScreenContext()
        let interactable = try await client.getInteractableElements()
        let described = try await client.findByDescription("login button")

        XCTAssertFalse(context.summary.isEmpty)
        XCTAssertFalse(interactable.isEmpty)
        XCTAssertFalse(described.isEmpty)
    }

    // MARK: - Shutdown

    func testShutdownIsSafeOnTheInMemoryClient() async {
        let client = makeClient()
        // No transport was opened, so shutdown must be a no-op rather than a crash.
        await client.shutdown()
    }
}
