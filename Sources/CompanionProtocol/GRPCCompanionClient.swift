import AmooCore

// swiftlint:disable file_length
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Protos

// swiftformat:disable wrapMultilineStatementBraces

package protocol CompanionRPCClient: Sendable {
    // Session
    func startSession(_ request: Amoo_StartSessionRequest) async throws -> Amoo_StartSessionResponse
    func getCapabilities(_ request: Amoo_CapabilitiesRequest) async throws
        -> Amoo_CapabilitiesResponse
    func endSession(_ request: Amoo_EndSessionRequest) async throws -> Amoo_EndSessionResponse

    // Touch
    func tap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse
    func doubleTap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse
    func longPress(_ request: Amoo_LongPressRequest) async throws -> Amoo_ActionResponse
    func tapElement(_ request: Amoo_TapElementRequest) async throws -> Amoo_ActionResponse

    // Gestures
    func swipe(_ request: Amoo_SwipeRequest) async throws -> Amoo_ActionResponse
    func swipeInDirection(_ request: Amoo_SwipeDirectionRequest) async throws -> Amoo_ActionResponse
    func scroll(_ request: Amoo_ScrollRequest) async throws -> Amoo_ActionResponse
    func drag(_ request: Amoo_DragRequest) async throws -> Amoo_ActionResponse

    // Text
    func typeText(_ request: Amoo_TypeTextRequest) async throws -> Amoo_ActionResponse
    func clearText(_ request: Amoo_ClearTextRequest) async throws -> Amoo_ActionResponse
    func setText(_ request: Amoo_SetTextRequest) async throws -> Amoo_ActionResponse

    // Navigation
    func pressBack(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse
    func pressHome(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse

    // Accessibility
    func findElements(_ request: Amoo_FindElementsRequest) async throws -> Amoo_FindElementsResponse
    func getViewHierarchy(
        _ request: Amoo_ViewHierarchyRequest
    ) async throws -> Amoo_ViewHierarchyResponse
    func waitForElement(
        _ request: Amoo_WaitForElementRequest
    ) async throws -> Amoo_WaitForElementResponse
    func isKeyboardVisible(_ request: Amoo_Empty) async throws -> Amoo_KeyboardVisibleResponse
    func getCurrentApp(_ request: Amoo_Empty) async throws -> Amoo_CurrentAppResponse
    func getScreenInfo(_ request: Amoo_Empty) async throws -> Amoo_ScreenInfoResponse
    func setTargetApp(_ request: Amoo_SetTargetAppRequest) async throws -> Amoo_ActionResponse
    func getAppState(_ request: Amoo_GetAppStateRequest) async throws -> Amoo_GetAppStateResponse

    /// Capture
    func takeScreenshot(_ request: Amoo_ScreenshotRequest) async throws -> Amoo_ScreenshotResponse

    /// AI
    func getScreenContext(
        _ request: Amoo_ScreenContextRequest
    ) async throws -> Amoo_ScreenContextResponse
    func findByDescription(
        _ request: Amoo_FindByDescriptionRequest
    ) async throws -> Amoo_FindElementsResponse
    func getInteractableElements(
        _ request: Amoo_Empty
    ) async throws -> Amoo_InteractableElementsResponse

    func shutdown() async
}

package extension CompanionRPCClient {
    func shutdown() async {}

    func setText(_: Amoo_SetTextRequest) async throws -> Amoo_ActionResponse {
        throw AmooError.notImplemented("setText RPC")
    }
}

// MARK: - GeneratedCompanionRPCClient

package struct GeneratedCompanionRPCClient: CompanionRPCClient {
    private let client: any Amoo_CompanionService.ClientProtocol

    package init(client: any Amoo_CompanionService.ClientProtocol) {
        self.client = client
    }

    package func startSession(_ request: Amoo_StartSessionRequest) async throws
        -> Amoo_StartSessionResponse {
        try await client.startSession(request)
    }

    package func getCapabilities(
        _ request: Amoo_CapabilitiesRequest
    ) async throws -> Amoo_CapabilitiesResponse {
        try await client.getCapabilities(request)
    }

    package func endSession(_ request: Amoo_EndSessionRequest) async throws
        -> Amoo_EndSessionResponse {
        try await client.endSession(request)
    }

    package func tap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        try await client.tap(request)
    }

    package func doubleTap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        try await client.doubleTap(request)
    }

    package func longPress(_ request: Amoo_LongPressRequest) async throws -> Amoo_ActionResponse {
        try await client.longPress(request)
    }

    package func tapElement(_ request: Amoo_TapElementRequest) async throws -> Amoo_ActionResponse {
        try await client.tapElement(request)
    }

    package func swipe(_ request: Amoo_SwipeRequest) async throws -> Amoo_ActionResponse {
        try await client.swipe(request)
    }

    package func swipeInDirection(_ request: Amoo_SwipeDirectionRequest) async throws
        -> Amoo_ActionResponse {
        try await client.swipeInDirection(request)
    }

    package func scroll(_ request: Amoo_ScrollRequest) async throws -> Amoo_ActionResponse {
        try await client.scroll(request)
    }

    package func drag(_ request: Amoo_DragRequest) async throws -> Amoo_ActionResponse {
        try await client.drag(request)
    }

    package func typeText(_ request: Amoo_TypeTextRequest) async throws -> Amoo_ActionResponse {
        try await client.typeText(request)
    }

    package func clearText(_ request: Amoo_ClearTextRequest) async throws -> Amoo_ActionResponse {
        try await client.clearText(request)
    }

    package func setText(_ request: Amoo_SetTextRequest) async throws -> Amoo_ActionResponse {
        try await client.setText(request)
    }

    package func pressBack(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        try await client.pressBack(request)
    }

    package func pressHome(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        try await client.pressHome(request)
    }

    package func findElements(_ request: Amoo_FindElementsRequest) async throws
        -> Amoo_FindElementsResponse {
        try await client.findElements(request)
    }

    package func getViewHierarchy(
        _ request: Amoo_ViewHierarchyRequest
    ) async throws -> Amoo_ViewHierarchyResponse {
        try await client.getViewHierarchy(request)
    }

    package func waitForElement(
        _ request: Amoo_WaitForElementRequest
    ) async throws -> Amoo_WaitForElementResponse {
        try await client.waitForElement(request)
    }

    package func isKeyboardVisible(_ request: Amoo_Empty) async throws
        -> Amoo_KeyboardVisibleResponse {
        try await client.isKeyboardVisible(request)
    }

    package func getCurrentApp(_ request: Amoo_Empty) async throws
        -> Amoo_CurrentAppResponse {
        try await client.getCurrentApp(request)
    }

    package func getScreenInfo(_ request: Amoo_Empty) async throws
        -> Amoo_ScreenInfoResponse {
        try await client.getScreenInfo(request)
    }

    package func setTargetApp(_ request: Amoo_SetTargetAppRequest) async throws
        -> Amoo_ActionResponse {
        try await client.setTargetApp(request)
    }

    package func getAppState(_ request: Amoo_GetAppStateRequest) async throws
        -> Amoo_GetAppStateResponse {
        try await client.getAppState(request)
    }

    package func takeScreenshot(_ request: Amoo_ScreenshotRequest) async throws
        -> Amoo_ScreenshotResponse {
        try await client.takeScreenshot(request)
    }

    package func getScreenContext(
        _ request: Amoo_ScreenContextRequest
    ) async throws -> Amoo_ScreenContextResponse {
        try await client.getScreenContext(request)
    }

    package func findByDescription(
        _ request: Amoo_FindByDescriptionRequest
    ) async throws -> Amoo_FindElementsResponse {
        try await client.findByDescription(request)
    }

    package func getInteractableElements(
        _ request: Amoo_Empty
    ) async throws -> Amoo_InteractableElementsResponse {
        try await client.getInteractableElements(request)
    }
}

// MARK: - InMemoryCompanionRPCClient

package struct InMemoryCompanionRPCClient: CompanionRPCClient {
    package init() {}

    package func startSession(_ request: Amoo_StartSessionRequest) async throws
        -> Amoo_StartSessionResponse {
        var response = Amoo_StartSessionResponse()
        response.sessionID = request.requestedSessionID.isEmpty ? UUID().uuidString : request.requestedSessionID
        return response
    }

    package func getCapabilities(
        _ request: Amoo_CapabilitiesRequest
    ) async throws -> Amoo_CapabilitiesResponse {
        _ = request

        var requiredCapability = Amoo_CapabilityDescriptor()
        requiredCapability.key = "action.tap"
        requiredCapability.tier = .required
        requiredCapability.supported = true

        var queryCapability = Amoo_CapabilityDescriptor()
        queryCapability.key = "query.findElements"
        queryCapability.tier = .required
        queryCapability.supported = true

        var response = Amoo_CapabilitiesResponse()
        response.capabilities = [requiredCapability, queryCapability]
        return response
    }

    package func endSession(_ request: Amoo_EndSessionRequest) async throws
        -> Amoo_EndSessionResponse {
        _ = request

        var response = Amoo_EndSessionResponse()
        response.ended = true
        return response
    }

    package func tap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func doubleTap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func longPress(_ request: Amoo_LongPressRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func tapElement(_ request: Amoo_TapElementRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func swipe(_ request: Amoo_SwipeRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func swipeInDirection(_ request: Amoo_SwipeDirectionRequest) async throws
        -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func scroll(_ request: Amoo_ScrollRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func drag(_ request: Amoo_DragRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func typeText(_ request: Amoo_TypeTextRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func clearText(_ request: Amoo_ClearTextRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func setText(_ request: Amoo_SetTextRequest) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func pressBack(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func pressHome(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func findElements(_ request: Amoo_FindElementsRequest) async throws
        -> Amoo_FindElementsResponse {
        var element = Amoo_ElementInfo()
        element.id = request.selector.id.isEmpty ? "sample" : request.selector.id
        element.label = request.selector.label.isEmpty ? "sample" : request.selector.label

        var response = Amoo_FindElementsResponse()
        response.elements = [element]
        return response
    }

    package func getViewHierarchy(
        _ request: Amoo_ViewHierarchyRequest
    ) async throws -> Amoo_ViewHierarchyResponse {
        _ = request

        var root = Amoo_ViewNode()
        root.id = "root"

        var response = Amoo_ViewHierarchyResponse()
        response.root = root
        return response
    }

    package func waitForElement(
        _ request: Amoo_WaitForElementRequest
    ) async throws -> Amoo_WaitForElementResponse {
        _ = request
        var response = Amoo_WaitForElementResponse()
        response.found = true
        return response
    }

    package func isKeyboardVisible(_ request: Amoo_Empty) async throws
        -> Amoo_KeyboardVisibleResponse {
        _ = request
        var response = Amoo_KeyboardVisibleResponse()
        response.visible = false
        return response
    }

    package func getCurrentApp(_ request: Amoo_Empty) async throws
        -> Amoo_CurrentAppResponse {
        _ = request
        return Amoo_CurrentAppResponse()
    }

    package func getScreenInfo(_ request: Amoo_Empty) async throws
        -> Amoo_ScreenInfoResponse {
        _ = request
        return Amoo_ScreenInfoResponse()
    }

    package func setTargetApp(_ request: Amoo_SetTargetAppRequest) async throws
        -> Amoo_ActionResponse {
        _ = request
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }

    package func getAppState(_ request: Amoo_GetAppStateRequest) async throws
        -> Amoo_GetAppStateResponse {
        _ = request
        var response = Amoo_GetAppStateResponse()
        response.state = "unknown"
        return response
    }

    package func takeScreenshot(_ request: Amoo_ScreenshotRequest) async throws
        -> Amoo_ScreenshotResponse {
        _ = request
        var response = Amoo_ScreenshotResponse()
        response.data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        return response
    }

    package func getScreenContext(
        _ request: Amoo_ScreenContextRequest
    ) async throws -> Amoo_ScreenContextResponse {
        _ = request

        var response = Amoo_ScreenContextResponse()
        response.summary = "Empty screen context"
        return response
    }

    package func findByDescription(
        _ request: Amoo_FindByDescriptionRequest
    ) async throws -> Amoo_FindElementsResponse {
        var element = Amoo_ElementInfo()
        element.id = "fixture-home-title"
        element.label = request.description_p.isEmpty ? "Fixture Home" : request.description_p

        var response = Amoo_FindElementsResponse()
        response.elements = [element]
        return response
    }

    package func getInteractableElements(
        _ request: Amoo_Empty
    ) async throws -> Amoo_InteractableElementsResponse {
        _ = request

        var element = Amoo_ElementInfo()
        element.id = "fixture-open-details"
        element.label = "Open Details"

        var response = Amoo_InteractableElementsResponse()
        response.elements = [element]
        return response
    }

    private func successActionResponse() -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }
}

// MARK: - LiveCompanionRPCClient

package actor LiveCompanionRPCClient: CompanionRPCClient {
    private static var gestureCallOptions: GRPCCore.CallOptions {
        var options = GRPCCore.CallOptions.defaults
        // XCUITest can wedge on beta runtimes. A deadline keeps the client usable and makes
        // recovery (`amoo companion start --force`) possible instead of hanging forever.
        options.timeout = .seconds(12)
        return options
    }

    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let client: Amoo_CompanionService.Client<HTTP2ClientTransport.Posix>
    private let connectionTask: Task<Void, Never>

    package init(connection: CompanionConnection) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: connection.host, port: connection.port),
            transportSecurity: .plaintext
        )
        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        client = Amoo_CompanionService.Client(wrapping: grpcClient)
        connectionTask = Task {
            do {
                try await grpcClient.runConnections()
            } catch {
                // Connection errors are surfaced on RPC calls.
            }
        }
    }

    deinit {
        grpcClient.beginGracefulShutdown()
        connectionTask.cancel()
    }

    package func startSession(_ request: Amoo_StartSessionRequest) async throws
        -> Amoo_StartSessionResponse {
        try await client.startSession(request)
    }

    package func getCapabilities(
        _ request: Amoo_CapabilitiesRequest
    ) async throws -> Amoo_CapabilitiesResponse {
        try await client.getCapabilities(request)
    }

    package func endSession(_ request: Amoo_EndSessionRequest) async throws
        -> Amoo_EndSessionResponse {
        try await client.endSession(request)
    }

    package func tap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        try await client.tap(request)
    }

    package func doubleTap(_ request: Amoo_TapRequest) async throws -> Amoo_ActionResponse {
        try await client.doubleTap(request)
    }

    package func longPress(_ request: Amoo_LongPressRequest) async throws -> Amoo_ActionResponse {
        try await client.longPress(request)
    }

    package func tapElement(_ request: Amoo_TapElementRequest) async throws -> Amoo_ActionResponse {
        try await client.tapElement(request)
    }

    package func swipe(_ request: Amoo_SwipeRequest) async throws -> Amoo_ActionResponse {
        try await client.swipe(request, options: Self.gestureCallOptions)
    }

    package func swipeInDirection(_ request: Amoo_SwipeDirectionRequest) async throws
        -> Amoo_ActionResponse {
        try await client.swipeInDirection(request, options: Self.gestureCallOptions)
    }

    package func scroll(_ request: Amoo_ScrollRequest) async throws -> Amoo_ActionResponse {
        try await client.scroll(request, options: Self.gestureCallOptions)
    }

    package func drag(_ request: Amoo_DragRequest) async throws -> Amoo_ActionResponse {
        try await client.drag(request, options: Self.gestureCallOptions)
    }

    package func typeText(_ request: Amoo_TypeTextRequest) async throws -> Amoo_ActionResponse {
        try await client.typeText(request)
    }

    package func clearText(_ request: Amoo_ClearTextRequest) async throws -> Amoo_ActionResponse {
        try await client.clearText(request)
    }

    package func setText(_ request: Amoo_SetTextRequest) async throws -> Amoo_ActionResponse {
        try await client.setText(request)
    }

    package func pressBack(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        try await client.pressBack(request)
    }

    package func pressHome(_ request: Amoo_Empty) async throws -> Amoo_ActionResponse {
        try await client.pressHome(request)
    }

    package func findElements(_ request: Amoo_FindElementsRequest) async throws
        -> Amoo_FindElementsResponse {
        try await client.findElements(request)
    }

    package func getViewHierarchy(
        _ request: Amoo_ViewHierarchyRequest
    ) async throws -> Amoo_ViewHierarchyResponse {
        try await client.getViewHierarchy(request)
    }

    package func waitForElement(
        _ request: Amoo_WaitForElementRequest
    ) async throws -> Amoo_WaitForElementResponse {
        try await client.waitForElement(request)
    }

    package func isKeyboardVisible(_ request: Amoo_Empty) async throws
        -> Amoo_KeyboardVisibleResponse {
        try await client.isKeyboardVisible(request)
    }

    package func getCurrentApp(_ request: Amoo_Empty) async throws
        -> Amoo_CurrentAppResponse {
        try await client.getCurrentApp(request)
    }

    package func getScreenInfo(_ request: Amoo_Empty) async throws
        -> Amoo_ScreenInfoResponse {
        try await client.getScreenInfo(request)
    }

    package func setTargetApp(_ request: Amoo_SetTargetAppRequest) async throws
        -> Amoo_ActionResponse {
        try await client.setTargetApp(request)
    }

    package func getAppState(_ request: Amoo_GetAppStateRequest) async throws
        -> Amoo_GetAppStateResponse {
        try await client.getAppState(request)
    }

    package func takeScreenshot(_ request: Amoo_ScreenshotRequest) async throws
        -> Amoo_ScreenshotResponse {
        try await client.takeScreenshot(request)
    }

    package func getScreenContext(
        _ request: Amoo_ScreenContextRequest
    ) async throws -> Amoo_ScreenContextResponse {
        try await client.getScreenContext(request)
    }

    package func findByDescription(
        _ request: Amoo_FindByDescriptionRequest
    ) async throws -> Amoo_FindElementsResponse {
        try await client.findByDescription(request)
    }

    package func getInteractableElements(
        _ request: Amoo_Empty
    ) async throws -> Amoo_InteractableElementsResponse {
        try await client.getInteractableElements(request)
    }

    package func shutdown() async {
        grpcClient.beginGracefulShutdown()
        connectionTask.cancel()
        _ = await connectionTask.result
    }
}

// MARK: - GRPCCompanionClient

public actor GRPCCompanionClient: CompanionClient {
    private let rpcClient: any CompanionRPCClient
    private let connection: CompanionConnection
    private var sessionID: String?

    /// Construct an in-memory stub client. Useful for tests and offline development —
    /// it does **not** open a network connection. For a real gRPC client use
    /// ``makeLive(connection:)``.
    public init(connection: CompanionConnection) {
        self.connection = connection
        rpcClient = InMemoryCompanionRPCClient()
    }

    /// Construct a client backed by a live gRPC connection.
    public static func makeLive(connection: CompanionConnection) throws -> GRPCCompanionClient {
        let rpcClient = try LiveCompanionRPCClient(connection: connection)
        return GRPCCompanionClient(connection: connection, rpcClient: rpcClient)
    }

    package init(connection: CompanionConnection, rpcClient: any CompanionRPCClient) {
        self.connection = connection
        self.rpcClient = rpcClient
    }

    package init(
        connection: CompanionConnection,
        generatedClient: any Amoo_CompanionService.ClientProtocol
    ) {
        self.connection = connection
        rpcClient = GeneratedCompanionRPCClient(client: generatedClient)
    }

    // MARK: - Session

    public func startSession() async throws {
        var request = Amoo_StartSessionRequest()
        request.requestedSessionID = sessionID ?? UUID().uuidString

        let response = try await rpcClient.startSession(request)
        sessionID = response.sessionID.isEmpty ? request.requestedSessionID : response.sessionID
    }

    public func getCapabilities() async throws -> [CapabilityDescriptor] {
        let response = try await rpcClient.getCapabilities(Amoo_CapabilitiesRequest())
        return response.capabilities.map { descriptor in
            CapabilityDescriptor(
                key: descriptor.key,
                tier: descriptor.tier.coreTier,
                supported: descriptor.supported,
                reasonIfUnsupported: descriptor.reasonIfUnsupported.nonEmpty
            )
        }
    }

    public func endSession() async throws {
        var request = Amoo_EndSessionRequest()
        request.sessionID = sessionID ?? ""

        _ = try await rpcClient.endSession(request)
        sessionID = nil
    }

    // MARK: - Touch

    public func tap(at point: Point) async throws {
        var request = Amoo_TapRequest()
        request.point = point.protoPoint

        let response = try await rpcClient.tap(request)
        try validate(response: response, action: "tap")
    }

    public func doubleTap(at point: Point) async throws {
        var request = Amoo_TapRequest()
        request.point = point.protoPoint

        let response = try await rpcClient.doubleTap(request)
        try validate(response: response, action: "doubleTap")
    }

    public func longPress(at point: Point, duration: Duration) async throws {
        var request = Amoo_LongPressRequest()
        request.point = point.protoPoint
        var dur = Amoo_Duration()
        dur.milliseconds = Int32(duration.milliseconds)
        request.duration = dur

        let response = try await rpcClient.longPress(request)
        try validate(response: response, action: "longPress")
    }

    public func tapElement(
        _ selector: ElementSelector,
        appID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async throws {
        var request = Amoo_TapElementRequest()
        request.selector = selector.protoSelector
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.tapElement(request)
        try validate(response: response, action: "tapElement")
    }

    // MARK: - Gestures

    public func swipe(from: Point, to: Point, duration: Duration) async throws {
        var request = Amoo_SwipeRequest()
        request.from = from.protoPoint
        request.to = to.protoPoint
        var dur = Amoo_Duration()
        dur.milliseconds = Int32(duration.milliseconds)
        request.duration = dur

        let response = try await rpcClient.swipe(request)
        try validate(response: response, action: "swipe")
    }

    /// Presses at `from`, holds for `holdDuration` so the target can register a
    /// long-press, then moves to `to` over `duration` before releasing. This is
    /// what distinguishes a drag from a swipe — a swipe never dwells at the origin.
    public func drag(from: Point, to: Point, duration: Duration, holdDuration: Duration) async throws {
        var request = Amoo_DragRequest()
        request.from = from.protoPoint
        request.to = to.protoPoint
        var dur = Amoo_Duration()
        dur.milliseconds = Int32(duration.milliseconds)
        request.duration = dur
        var hold = Amoo_Duration()
        hold.milliseconds = Int32(holdDuration.milliseconds)
        request.holdDuration = hold

        let response = try await rpcClient.drag(request)
        try validate(response: response, action: "drag")
    }

    public func swipeInDirection(
        _ direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws {
        var request = Amoo_SwipeDirectionRequest()
        request.direction = direction.protoDirection
        request.distance = Float(distance)
        request.durationMs = Int32(duration.milliseconds)
        if let element {
            request.selector = element.protoSelector
        }

        let response = try await rpcClient.swipeInDirection(request)
        try validate(response: response, action: "swipeInDirection")
    }

    public func scroll(direction: Direction, distance: Double) async throws {
        var request = Amoo_ScrollRequest()
        request.direction = direction.protoDirection
        request.distance = Float(distance)

        let response = try await rpcClient.scroll(request)
        try validate(response: response, action: "scroll")
    }

    // MARK: - Text

    public func typeText(_ text: String) async throws {
        var request = Amoo_TypeTextRequest()
        request.text = text

        let response = try await rpcClient.typeText(request)
        try validate(response: response, action: "typeText")
    }

    public func clearText(characterCount: Int?) async throws {
        var request = Amoo_ClearTextRequest()
        request.characterCount = Int32(characterCount ?? 0)

        let response = try await rpcClient.clearText(request)
        try validate(response: response, action: "clearText")
    }

    public func setText(
        _ selector: ElementSelector,
        text: String,
        appID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async throws {
        var request = Amoo_SetTextRequest()
        request.selector = selector.protoSelector
        request.text = text
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.setText(request)
        try validate(response: response, action: "setText")
    }

    // MARK: - Navigation

    public func pressBack() async throws {
        let response = try await rpcClient.pressBack(Amoo_Empty())
        try validate(response: response, action: "pressBack")
    }

    public func pressHome() async throws {
        let response = try await rpcClient.pressHome(Amoo_Empty())
        try validate(response: response, action: "pressHome")
    }

    // MARK: - Accessibility

    public func findElements(
        _ selector: ElementSelector,
        appID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async throws
        -> [ElementInfo] {
        var request = Amoo_FindElementsRequest()
        request.selector = selector.protoSelector
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.findElements(request)
        return response.elements.map(\.coreElementInfo)
    }

    public func getViewHierarchy(appID: String? = nil, candidateBundleIDs: [String] = []) async throws -> ViewNode {
        var request = Amoo_ViewHierarchyRequest()
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs
        let response = try await rpcClient.getViewHierarchy(request)
        return response.root.coreViewNode
    }

    public func waitForElement(
        _ selector: ElementSelector,
        timeout: Duration,
        appID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async throws {
        var request = Amoo_WaitForElementRequest()
        request.selector = selector.protoSelector
        var dur = Amoo_Duration()
        dur.milliseconds = Int32(timeout.milliseconds)
        request.timeout = dur
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.waitForElement(request)
        if !response.found {
            throw AmooError.timeout(operation: "waitForElement", duration: timeout)
        }
    }

    public func isKeyboardVisible() async throws -> Bool {
        let response = try await rpcClient.isKeyboardVisible(Amoo_Empty())
        return response.visible
    }

    // MARK: - Target app

    public func currentApp() async throws -> CurrentAppInfo {
        let response = try await rpcClient.getCurrentApp(Amoo_Empty())
        return CurrentAppInfo(
            bundleID: response.bundleID,
            targetBundleID: response.targetBundleID
        )
    }

    public func screenInfo() async throws -> ScreenGeometry {
        try await Self.geometry(from: rpcClient.getScreenInfo(Amoo_Empty()))
    }

    static func geometry(from response: Amoo_ScreenInfoResponse) -> ScreenGeometry {
        ScreenGeometry(
            widthPoints: response.widthPoints,
            heightPoints: response.heightPoints,
            widthPixels: response.widthPixels,
            heightPixels: response.heightPixels,
            scale: response.scale
        )
    }

    public func setTargetApp(bundleID: String?) async throws {
        var request = Amoo_SetTargetAppRequest()
        request.bundleID = bundleID ?? ""
        _ = try await rpcClient.setTargetApp(request)
    }

    public func appState(appID: String) async throws -> String {
        var request = Amoo_GetAppStateRequest()
        request.appID = appID
        return try await rpcClient.getAppState(request).state
    }

    // MARK: - Capture

    public func takeScreenshot() async throws -> ScreenshotData {
        let response = try await rpcClient.takeScreenshot(Amoo_ScreenshotRequest())
        return ScreenshotData(bytes: [UInt8](response.data))
    }

    // MARK: - AI

    public func getScreenContext() async throws -> ScreenContext {
        var request = Amoo_ScreenContextRequest()
        request.format = "summary"

        let response = try await rpcClient.getScreenContext(request)
        return ScreenContext(summary: response.summary.nonEmpty ?? "Empty screen context")
    }

    public func getInteractableElements() async throws -> [ElementInfo] {
        let response = try await rpcClient.getInteractableElements(Amoo_Empty())
        return response.elements.map(\.coreElementInfo)
    }

    public func findByDescription(_ description: String) async throws -> [ElementInfo] {
        var request = Amoo_FindByDescriptionRequest()
        request.description_p = description
        let response = try await rpcClient.findByDescription(request)
        return response.elements.map(\.coreElementInfo)
    }

    // MARK: - Lifecycle

    public func shutdown() async {
        await rpcClient.shutdown()
    }

    // MARK: - Private

    private func validate(response: Amoo_ActionResponse, action: String) throws {
        guard response.success else {
            // Runtime action failures (element not found, tap missed) — these are not
            // capability-negotiation problems. Surface them as commandFailed so callers
            // catching AmooError.commandFailed see them as expected.
            let reason = response.message.nonEmpty ?? "unknown"
            throw AmooError.commandFailed(command: action, output: reason)
        }
    }
}

// MARK: - Proto Conversions

private extension CapabilityTier {
    static func from(_ tier: Amoo_CapabilityTier) -> Self {
        switch tier {
        case .required:
            .required
        case .optional, .unspecified, .UNRECOGNIZED:
            .optional
        }
    }
}

private extension Amoo_CapabilityTier {
    var coreTier: CapabilityTier {
        .from(self)
    }
}

private extension Point {
    var protoPoint: Amoo_Point {
        var point = Amoo_Point()
        point.x = x
        point.y = y
        return point
    }
}

private extension Direction {
    var protoDirection: Amoo_Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

private extension Amoo_ElementInfo {
    var coreElementInfo: ElementInfo {
        ElementInfo(
            id: id.nonEmpty ?? "",
            label: label.nonEmpty ?? "",
            value: value.nonEmpty,
            type: ElementType(rawValue: type.lowercased()),
            frame: hasFrame ? frame.coreRect : nil,
            hitPoint: hasHitPoint ? hitPoint.corePoint : nil,
            isEnabled: isEnabled,
            isVisible: isVisible
        )
    }
}

private extension Amoo_ViewNode {
    var coreViewNode: ViewNode {
        ViewNode(
            id: id.nonEmpty ?? "",
            label: label.nonEmpty ?? "",
            value: value.nonEmpty,
            type: ElementType(rawValue: type.lowercased()),
            frame: hasFrame ? frame.coreRect : nil,
            hitPoint: hasHitPoint ? hitPoint.corePoint : nil,
            isEnabled: isEnabled,
            isVisible: isVisible,
            children: children.map(\.coreViewNode)
        )
    }
}

private extension Amoo_Rect {
    var coreRect: Rect {
        Rect(x: x, y: y, width: width, height: height)
    }
}

private extension Amoo_Point {
    var corePoint: Point {
        Point(x: x, y: y)
    }
}

private extension ElementSelector {
    var protoSelector: Amoo_ElementSelector {
        var selector = Amoo_ElementSelector()

        if let id {
            selector.id = id
        }

        if let label {
            selector.label = label
        }

        if let containsText {
            selector.containsText = containsText
        }

        if let description {
            selector.description_p = description
        }

        selector.labeledOnly = labeledOnly

        if let parentSelector {
            switch parentSelector {
            case let .selector(parent):
                selector.parentSelector = parent.protoSelector
            }
        }

        return selector
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// swiftformat:enable wrapMultilineStatementBraces
