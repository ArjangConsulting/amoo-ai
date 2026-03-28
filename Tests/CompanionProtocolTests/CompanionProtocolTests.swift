@testable import CompanionProtocol
import MobileTestingCore
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

    func testLiveFactoryBuildsClient() async throws {
        let client = try GRPCCompanionClient.makeLive(connection: .init(host: "127.0.0.1", port: 22087))
        await client.shutdown()
    }
}

private actor MockRPCClient: CompanionRPCClient {
    private let screenshotPNG = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2foAAAAASUVORK5CYII="
    )!

    var startRequest: MobileTesting_StartSessionRequest?
    var tapRequest: MobileTesting_TapRequest?
    var findElementsRequest: MobileTesting_FindElementsRequest?
    var tapElementRequest: MobileTesting_TapElementRequest?
    var swipeRequest: MobileTesting_SwipeRequest?
    var typeTextRequest: MobileTesting_TypeTextRequest?
    var clearTextRequest: MobileTesting_ClearTextRequest?
    var waitForElementRequest: MobileTesting_WaitForElementRequest?
    var actionCalls: [String] = []

    func startSession(_ request: MobileTesting_StartSessionRequest) async throws -> MobileTesting_StartSessionResponse {
        startRequest = request

        var response = MobileTesting_StartSessionResponse()
        response.sessionID = "session-123"
        return response
    }

    func getCapabilities(_ request: MobileTesting_CapabilitiesRequest) async throws
        -> MobileTesting_CapabilitiesResponse {
        _ = request

        var capability = MobileTesting_CapabilityDescriptor()
        capability.key = "query.findElements"
        capability.tier = .required
        capability.supported = true

        var response = MobileTesting_CapabilitiesResponse()
        response.capabilities = [capability]
        return response
    }

    func endSession(_ request: MobileTesting_EndSessionRequest) async throws -> MobileTesting_EndSessionResponse {
        _ = request

        var response = MobileTesting_EndSessionResponse()
        response.ended = true
        return response
    }

    func tap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        tapRequest = request
        return successResponse()
    }

    func doubleTap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        actionCalls.append("doubleTap")
        return successResponse()
    }

    func longPress(_ request: MobileTesting_LongPressRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        actionCalls.append("longPress")
        return successResponse()
    }

    func tapElement(_ request: MobileTesting_TapElementRequest) async throws -> MobileTesting_ActionResponse {
        tapElementRequest = request
        actionCalls.append("tapElement")
        return successResponse()
    }

    func swipe(_ request: MobileTesting_SwipeRequest) async throws -> MobileTesting_ActionResponse {
        swipeRequest = request
        actionCalls.append("swipe")
        return successResponse()
    }

    func scroll(_ request: MobileTesting_ScrollRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        actionCalls.append("scroll")
        return successResponse()
    }

    func typeText(_ request: MobileTesting_TypeTextRequest) async throws -> MobileTesting_ActionResponse {
        typeTextRequest = request
        actionCalls.append("typeText")
        return successResponse()
    }

    func clearText(_ request: MobileTesting_ClearTextRequest) async throws -> MobileTesting_ActionResponse {
        clearTextRequest = request
        actionCalls.append("clearText")
        return successResponse()
    }

    func pressBack(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        _ = request
        actionCalls.append("pressBack")
        return successResponse()
    }

    func pressHome(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        _ = request
        actionCalls.append("pressHome")
        return successResponse()
    }

    func findElements(_ request: MobileTesting_FindElementsRequest) async throws -> MobileTesting_FindElementsResponse {
        findElementsRequest = request

        var element = MobileTesting_ElementInfo()
        element.id = "element-1"
        element.label = "Login"
        element.isEnabled = false
        element.isVisible = false

        var response = MobileTesting_FindElementsResponse()
        response.elements = [element]
        return response
    }

    func getViewHierarchy(_ request: MobileTesting_ViewHierarchyRequest) async throws
        -> MobileTesting_ViewHierarchyResponse {
        _ = request

        var node = MobileTesting_ViewNode()
        node.id = "root-from-rpc"

        var response = MobileTesting_ViewHierarchyResponse()
        response.root = node
        return response
    }

    func waitForElement(_ request: MobileTesting_WaitForElementRequest) async throws
        -> MobileTesting_WaitForElementResponse {
        waitForElementRequest = request
        var response = MobileTesting_WaitForElementResponse()
        response.found = true
        return response
    }

    func isKeyboardVisible(_ request: MobileTesting_Empty) async throws -> MobileTesting_KeyboardVisibleResponse {
        _ = request
        var response = MobileTesting_KeyboardVisibleResponse()
        response.visible = true
        return response
    }

    func takeScreenshot(_ request: MobileTesting_ScreenshotRequest) async throws -> MobileTesting_ScreenshotResponse {
        _ = request
        var response = MobileTesting_ScreenshotResponse()
        response.data = screenshotPNG
        return response
    }

    func getScreenContext(_ request: MobileTesting_ScreenContextRequest) async throws
        -> MobileTesting_ScreenContextResponse {
        _ = request

        var response = MobileTesting_ScreenContextResponse()
        response.summary = "Summary from rpc client"
        return response
    }

    func findByDescription(_ request: MobileTesting_FindByDescriptionRequest) async throws
        -> MobileTesting_FindElementsResponse {
        var element = MobileTesting_ElementInfo()
        element.id = "description-1"
        element.label = request.description_p

        var response = MobileTesting_FindElementsResponse()
        response.elements = [element]
        return response
    }

    func getInteractableElements(_ request: MobileTesting_Empty) async throws
        -> MobileTesting_InteractableElementsResponse {
        _ = request

        var element = MobileTesting_ElementInfo()
        element.id = "action-1"
        element.label = "Open Details"

        var response = MobileTesting_InteractableElementsResponse()
        response.elements = [element]
        return response
    }

    func shutdown() async {
        actionCalls.append("shutdown")
    }

    private func successResponse() -> MobileTesting_ActionResponse {
        var response = MobileTesting_ActionResponse()
        response.success = true
        return response
    }
}

// swiftformat:enable wrapMultilineStatementBraces
