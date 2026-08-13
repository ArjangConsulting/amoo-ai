import AmooCore
@testable import CompanionProtocol
import Protos
import XCTest

// swiftformat:disable wrapMultilineStatementBraces

final class CompanionProtocolTests: XCTestCase {
    func testCapabilitiesAreReturned() async throws {
        let client = GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087))
        let capabilities = try await client.getCapabilities()
        XCTAssertFalse(capabilities.isEmpty)
    }

    func testSessionAndQueryMethods() async throws {
        let client = GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087))

        try await client.startSession()
        try await client.tap(at: Point(x: 1, y: 2))
        let hierarchy = try await client.getViewHierarchy()
        let context = try await client.getScreenContext()
        try await client.endSession()

        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertEqual(context.summary, "Empty screen context")
    }

    func testGRPCMappingUsesRPCClientResponses() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.startSession()
        try await client.tap(at: Point(x: 12, y: 34))

        let capabilities = try await client.getCapabilities()
        let elements = try await client.findElements(
            .init(
                id: "login",
                label: "Login",
                containsText: "Log",
                description: "Primary login button"
            )
        )

        let hierarchy = try await client.getViewHierarchy()
        let screenContext = try await client.getScreenContext()
        let interactable = try await client.getInteractableElements()
        let described = try await client.findByDescription("Fixture")
        try await client.endSession()

        XCTAssertEqual(capabilities.count, 1)
        XCTAssertEqual(capabilities.first?.key, "query.findElements")
        XCTAssertEqual(capabilities.first?.tier, .required)
        XCTAssertEqual(elements.first?.id, "element-1")
        XCTAssertEqual(elements.first?.label, "Login")
        XCTAssertEqual(elements.first?.isEnabled, false)
        XCTAssertEqual(elements.first?.isVisible, false)
        XCTAssertEqual(hierarchy.id, "root-from-rpc")
        XCTAssertEqual(screenContext.summary, "Summary from rpc client")
        XCTAssertEqual(interactable.first?.id, "action-1")
        XCTAssertEqual(described.first?.label, "Fixture")

        let startRequest = await rpcClient.startRequest
        XCTAssertEqual(startRequest?.requestedSessionID.isEmpty, false)

        let tapRequest = await rpcClient.tapRequest
        XCTAssertEqual(tapRequest?.point.x, 12)
        XCTAssertEqual(tapRequest?.point.y, 34)

        let findRequest = await rpcClient.findElementsRequest
        XCTAssertEqual(findRequest?.selector.id, "login")
        XCTAssertEqual(findRequest?.selector.label, "Login")
        XCTAssertEqual(findRequest?.selector.containsText, "Log")
        XCTAssertEqual(findRequest?.selector.description_p, "Primary login button")
    }

    func testNewActionsDelegate() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.doubleTap(at: Point(x: 5, y: 10))
        try await client.longPress(at: Point(x: 5, y: 10), duration: Duration(milliseconds: 500))
        try await client.scroll(direction: .down, distance: 300)
        try await client.clearText(characterCount: 5)

        let calls = await rpcClient.actionCalls
        XCTAssertEqual(calls, ["doubleTap", "longPress", "scroll", "clearText"])
    }

    func testAdditionalRPCDelegationAndSessionReuse() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.startSession()
        let firstRequest = await rpcClient.startRequest
        try await client.startSession()
        let secondRequest = await rpcClient.startRequest
        try await client.tapElement(.init(id: "login"), appID: "com.example", candidateBundleIDs: ["com.example.beta"])
        try await client.swipe(from: Point(x: 0, y: 0), to: Point(x: 4, y: 8), duration: Duration(milliseconds: 250))
        try await client.typeText("hello")
        try await client.pressBack()
        try await client.pressHome()
        try await client.waitForElement(.init(label: "Continue"), timeout: Duration(milliseconds: 500))
        let keyboardVisible = try await client.isKeyboardVisible()
        let screenshot = try await client.takeScreenshot()
        await client.shutdown()

        XCTAssertEqual(firstRequest?.requestedSessionID.isEmpty, false)
        XCTAssertEqual(secondRequest?.requestedSessionID, "session-123")
        XCTAssertTrue(keyboardVisible)
        XCTAssertEqual(screenshot.format, .png)

        let tapElementRequest = await rpcClient.tapElementRequest
        XCTAssertEqual(tapElementRequest?.selector.id, "login")
        XCTAssertEqual(tapElementRequest?.appID, "com.example")
        XCTAssertEqual(tapElementRequest?.candidateBundleIds, ["com.example.beta"])

        let swipeRequest = await rpcClient.swipeRequest
        XCTAssertEqual(swipeRequest?.from.x, 0)
        XCTAssertEqual(swipeRequest?.to.y, 8)

        let typeTextRequest = await rpcClient.typeTextRequest
        XCTAssertEqual(typeTextRequest?.text, "hello")

        let clearTextRequest = await rpcClient.clearTextRequest
        XCTAssertNil(clearTextRequest?.characterCount)

        let waitRequest = await rpcClient.waitForElementRequest
        XCTAssertEqual(waitRequest?.selector.label, "Continue")
        XCTAssertEqual(waitRequest?.timeout.milliseconds, 500)

        let calls = await rpcClient.actionCalls
        XCTAssertEqual(calls, ["tapElement", "swipe", "typeText", "pressBack", "pressHome", "shutdown"])
    }

    func testSwipeInDirectionDelegatesToRPC() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.swipeInDirection(.left, distance: 250, duration: Duration(milliseconds: 350), element: nil)

        let req = await rpcClient.swipeDirectionRequest
        XCTAssertEqual(req?.direction, .left)
        XCTAssertEqual(req?.distance, 250)
        XCTAssertEqual(req?.durationMs, 350)
        XCTAssertFalse(req?.hasSelector ?? true)

        let calls = await rpcClient.actionCalls
        XCTAssertTrue(calls.contains("swipeInDirection"))
    }

    func testSwipeInDirectionWithElementSelector() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.swipeInDirection(
            .right,
            distance: 200,
            duration: Duration(milliseconds: 300),
            element: ElementSelector(id: "card-list")
        )

        let req = await rpcClient.swipeDirectionRequest
        XCTAssertEqual(req?.direction, .right)
        XCTAssertTrue(req?.hasSelector ?? false)
        XCTAssertEqual(req?.selector.id, "card-list")
    }

    func testDragSendsHoldDurationSeparatelyFromTravelDuration() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.drag(
            from: Point(x: 10, y: 20),
            to: Point(x: 110, y: 220),
            duration: Duration(milliseconds: 400),
            holdDuration: Duration(milliseconds: 750)
        )

        let req = await rpcClient.dragRequest
        XCTAssertEqual(req?.from.x, 10)
        XCTAssertEqual(req?.to.y, 220)
        XCTAssertEqual(req?.duration.milliseconds, 400)
        // The hold is what makes this a drag rather than a swipe — it must survive
        // the trip across the wire as its own field.
        XCTAssertTrue(req?.hasHoldDuration ?? false)
        XCTAssertEqual(req?.holdDuration.milliseconds, 750)

        let calls = await rpcClient.actionCalls
        XCTAssertTrue(calls.contains("drag"))
        XCTAssertFalse(calls.contains("swipe"))
    }

    func testLiveFactoryBuildsClient() async throws {
        let client = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: 22087))
        await client.shutdown()
    }
}

private actor MockRPCClient: CompanionRPCClient {
    private let screenshotPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="
    )!

    var currentAppBundleID = "com.example.underTest"
    var targetAppBundleID = ""
    var startRequest: Amoo_StartSessionRequest?
    var tapRequest: Amoo_TapRequest?
    var findElementsRequest: Amoo_FindElementsRequest?
    var tapElementRequest: Amoo_TapElementRequest?
    var swipeRequest: Amoo_SwipeRequest?
    var dragRequest: Amoo_DragRequest?
    var swipeDirectionRequest: Amoo_SwipeDirectionRequest?
    var typeTextRequest: Amoo_TypeTextRequest?
    var clearTextRequest: Amoo_ClearTextRequest?
    var waitForElementRequest: Amoo_WaitForElementRequest?
    var actionCalls: [String] = []

    func startSession(_ request: Amoo_StartSessionRequest) async throws -> Amoo_StartSessionResponse {
        startRequest = request

        var response = Amoo_StartSessionResponse()
        response.sessionID = "session-123"
        return response
    }

    func getCapabilities(_ request: Amoo_CapabilitiesRequest) async throws
        -> Amoo_CapabilitiesResponse {
        _ = request

        var capability = Amoo_CapabilityDescriptor()
        capability.key = "query.findElements"
        capability.tier = .required
        capability.supported = true

        var response = Amoo_CapabilitiesResponse()
        response.capabilities = [capability]
        return response
    }

    func endSession(_ request: Amoo_EndSessionRequest) async throws -> Amoo_EndSessionResponse {
        _ = request

        var response = Amoo_EndSessionResponse()
        response.ended = true
        return response
    }

    func tap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        tapRequest = request
        return successResponse()
    }

    func doubleTap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        _ = request
        actionCalls.append("doubleTap")
        return successResponse()
    }

    func longPress(_ request: Amoo_LongPressRequest) async throws -> Amoo_ActionResponse {
        _ = request
        actionCalls.append("longPress")
        return successResponse()
    }

    func tapElement(_ request: Amoo_TapElementRequest) async throws -> Amoo_ActionResponse {
        tapElementRequest = request
        actionCalls.append("tapElement")
        return successResponse()
    }

    func swipe(_ request: Amoo_SwipeRequest) async throws -> Amoo_ActionResponse {
        swipeRequest = request
        actionCalls.append("swipe")
        return successResponse()
    }

    func drag(_ request: Amoo_DragRequest) async throws -> Amoo_ActionResponse {
        dragRequest = request
        actionCalls.append("drag")
        return successResponse()
    }

    func swipeInDirection(_ request: Amoo_SwipeDirectionRequest) async throws -> Amoo_ActionResponse {
        swipeDirectionRequest = request
        actionCalls.append("swipeInDirection")
        return successResponse()
    }

    func scroll(_ request: Amoo_ScrollRequest) async throws -> Amoo_ActionResponse {
        _ = request
        actionCalls.append("scroll")
        return successResponse()
    }

    func typeText(_ request: Amoo_TypeTextRequest) async throws -> Amoo_ActionResponse {
        typeTextRequest = request
        actionCalls.append("typeText")
        return successResponse()
    }

    func clearText(_ request: Amoo_ClearTextRequest) async throws -> Amoo_ActionResponse {
        clearTextRequest = request
        actionCalls.append("clearText")
        return successResponse()
    }

    func pressBack(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        _ = request
        actionCalls.append("pressBack")
        return successResponse()
    }

    func pressHome(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        _ = request
        actionCalls.append("pressHome")
        return successResponse()
    }

    func findElements(_ request: Amoo_FindElementsRequest) async throws -> Amoo_FindElementsResponse {
        findElementsRequest = request

        var element = Amoo_ElementInfo()
        element.id = "element-1"
        element.label = "Login"
        element.isEnabled = false
        element.isVisible = false

        var response = Amoo_FindElementsResponse()
        response.elements = [element]
        return response
    }

    func getViewHierarchy(_ request: Amoo_ViewHierarchyRequest) async throws
        -> Amoo_ViewHierarchyResponse {
        _ = request

        var node = Amoo_ViewNode()
        node.id = "root-from-rpc"

        var response = Amoo_ViewHierarchyResponse()
        response.root = node
        return response
    }

    func waitForElement(_ request: Amoo_WaitForElementRequest) async throws
        -> Amoo_WaitForElementResponse {
        waitForElementRequest = request
        var response = Amoo_WaitForElementResponse()
        response.found = true
        return response
    }

    func isKeyboardVisible(_ request: Amoo_Empty) async throws -> Amoo_KeyboardVisibleResponse {
        _ = request
        var response = Amoo_KeyboardVisibleResponse()
        response.visible = true
        return response
    }

    func getCurrentApp(_ request: Amoo_Empty) async throws -> Amoo_CurrentAppResponse {
        _ = request
        var response = Amoo_CurrentAppResponse()
        response.bundleID = currentAppBundleID
        response.targetBundleID = targetAppBundleID
        return response
    }

    func setTargetApp(_ request: Amoo_SetTargetAppRequest) async throws -> Amoo_ActionResponse {
        targetAppBundleID = request.bundleID
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }

    func takeScreenshot(_ request: Amoo_ScreenshotRequest) async throws -> Amoo_ScreenshotResponse {
        _ = request
        var response = Amoo_ScreenshotResponse()
        response.data = screenshotPNG
        return response
    }

    func getScreenContext(_ request: Amoo_ScreenContextRequest) async throws
        -> Amoo_ScreenContextResponse {
        _ = request

        var response = Amoo_ScreenContextResponse()
        response.summary = "Summary from rpc client"
        return response
    }

    func findByDescription(_ request: Amoo_FindByDescriptionRequest) async throws
        -> Amoo_FindElementsResponse {
        var element = Amoo_ElementInfo()
        element.id = "description-1"
        element.label = request.description_p

        var response = Amoo_FindElementsResponse()
        response.elements = [element]
        return response
    }

    func getInteractableElements(_ request: Amoo_Empty) async throws
        -> Amoo_InteractableElementsResponse {
        _ = request

        var element = Amoo_ElementInfo()
        element.id = "action-1"
        element.label = "Open Details"

        var response = Amoo_InteractableElementsResponse()
        response.elements = [element]
        return response
    }

    func shutdown() async {
        actionCalls.append("shutdown")
    }

    private func successResponse() -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }
}

// swiftformat:enable wrapMultilineStatementBraces
