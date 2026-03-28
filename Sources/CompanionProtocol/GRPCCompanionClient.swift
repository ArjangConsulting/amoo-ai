import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import MobileTestingCore
import Protos

// swiftformat:disable wrapMultilineStatementBraces

package protocol CompanionRPCClient: Sendable {
    // Session
    func startSession(_ request: MobileTesting_StartSessionRequest) async throws -> MobileTesting_StartSessionResponse
    func getCapabilities(_ request: MobileTesting_CapabilitiesRequest) async throws
        -> MobileTesting_CapabilitiesResponse
    func endSession(_ request: MobileTesting_EndSessionRequest) async throws -> MobileTesting_EndSessionResponse

    // Touch
    func tap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse
    func doubleTap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse
    func longPress(_ request: MobileTesting_LongPressRequest) async throws -> MobileTesting_ActionResponse
    func tapElement(_ request: MobileTesting_TapElementRequest) async throws -> MobileTesting_ActionResponse

    // Gestures
    func swipe(_ request: MobileTesting_SwipeRequest) async throws -> MobileTesting_ActionResponse
    func scroll(_ request: MobileTesting_ScrollRequest) async throws -> MobileTesting_ActionResponse

    // Text
    func typeText(_ request: MobileTesting_TypeTextRequest) async throws -> MobileTesting_ActionResponse
    func clearText(_ request: MobileTesting_ClearTextRequest) async throws -> MobileTesting_ActionResponse

    // Navigation
    func pressBack(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse
    func pressHome(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse

    // Accessibility
    func findElements(_ request: MobileTesting_FindElementsRequest) async throws -> MobileTesting_FindElementsResponse
    func getViewHierarchy(
        _ request: MobileTesting_ViewHierarchyRequest
    ) async throws -> MobileTesting_ViewHierarchyResponse
    func waitForElement(
        _ request: MobileTesting_WaitForElementRequest
    ) async throws -> MobileTesting_WaitForElementResponse
    func isKeyboardVisible(_ request: MobileTesting_Empty) async throws -> MobileTesting_KeyboardVisibleResponse

    // Capture
    func takeScreenshot(_ request: MobileTesting_ScreenshotRequest) async throws -> MobileTesting_ScreenshotResponse

    // AI
    func getScreenContext(
        _ request: MobileTesting_ScreenContextRequest
    ) async throws -> MobileTesting_ScreenContextResponse
    func findByDescription(
        _ request: MobileTesting_FindByDescriptionRequest
    ) async throws -> MobileTesting_FindElementsResponse
    func getInteractableElements(
        _ request: MobileTesting_Empty
    ) async throws -> MobileTesting_InteractableElementsResponse

    func shutdown() async
}

package extension CompanionRPCClient {
    func shutdown() async {}
}

// MARK: - GeneratedCompanionRPCClient

package struct GeneratedCompanionRPCClient: CompanionRPCClient {
    private let client: any MobileTesting_CompanionService.ClientProtocol

    package init(client: any MobileTesting_CompanionService.ClientProtocol) {
        self.client = client
    }

    package func startSession(_ request: MobileTesting_StartSessionRequest) async throws
        -> MobileTesting_StartSessionResponse {
        try await client.startSession(request)
    }

    package func getCapabilities(
        _ request: MobileTesting_CapabilitiesRequest
    ) async throws -> MobileTesting_CapabilitiesResponse {
        try await client.getCapabilities(request)
    }

    package func endSession(_ request: MobileTesting_EndSessionRequest) async throws
        -> MobileTesting_EndSessionResponse {
        try await client.endSession(request)
    }

    package func tap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        try await client.tap(request)
    }

    package func doubleTap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        try await client.doubleTap(request)
    }

    package func longPress(_ request: MobileTesting_LongPressRequest) async throws -> MobileTesting_ActionResponse {
        try await client.longPress(request)
    }

    package func tapElement(_ request: MobileTesting_TapElementRequest) async throws -> MobileTesting_ActionResponse {
        try await client.tapElement(request)
    }

    package func swipe(_ request: MobileTesting_SwipeRequest) async throws -> MobileTesting_ActionResponse {
        try await client.swipe(request)
    }

    package func scroll(_ request: MobileTesting_ScrollRequest) async throws -> MobileTesting_ActionResponse {
        try await client.scroll(request)
    }

    package func typeText(_ request: MobileTesting_TypeTextRequest) async throws -> MobileTesting_ActionResponse {
        try await client.typeText(request)
    }

    package func clearText(_ request: MobileTesting_ClearTextRequest) async throws -> MobileTesting_ActionResponse {
        try await client.clearText(request)
    }

    package func pressBack(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        try await client.pressBack(request)
    }

    package func pressHome(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        try await client.pressHome(request)
    }

    package func findElements(_ request: MobileTesting_FindElementsRequest) async throws
        -> MobileTesting_FindElementsResponse {
        try await client.findElements(request)
    }

    package func getViewHierarchy(
        _ request: MobileTesting_ViewHierarchyRequest
    ) async throws -> MobileTesting_ViewHierarchyResponse {
        try await client.getViewHierarchy(request)
    }

    package func waitForElement(
        _ request: MobileTesting_WaitForElementRequest
    ) async throws -> MobileTesting_WaitForElementResponse {
        try await client.waitForElement(request)
    }

    package func isKeyboardVisible(_ request: MobileTesting_Empty) async throws
        -> MobileTesting_KeyboardVisibleResponse {
        try await client.isKeyboardVisible(request)
    }

    package func takeScreenshot(_ request: MobileTesting_ScreenshotRequest) async throws
        -> MobileTesting_ScreenshotResponse {
        try await client.takeScreenshot(request)
    }

    package func getScreenContext(
        _ request: MobileTesting_ScreenContextRequest
    ) async throws -> MobileTesting_ScreenContextResponse {
        try await client.getScreenContext(request)
    }

    package func findByDescription(
        _ request: MobileTesting_FindByDescriptionRequest
    ) async throws -> MobileTesting_FindElementsResponse {
        try await client.findByDescription(request)
    }

    package func getInteractableElements(
        _ request: MobileTesting_Empty
    ) async throws -> MobileTesting_InteractableElementsResponse {
        try await client.getInteractableElements(request)
    }
}

// MARK: - InMemoryCompanionRPCClient

package struct InMemoryCompanionRPCClient: CompanionRPCClient {
    package init() {}

    package func startSession(_ request: MobileTesting_StartSessionRequest) async throws
        -> MobileTesting_StartSessionResponse {
        var response = MobileTesting_StartSessionResponse()
        response.sessionID = request.requestedSessionID.isEmpty ? UUID().uuidString : request.requestedSessionID
        return response
    }

    package func getCapabilities(
        _ request: MobileTesting_CapabilitiesRequest
    ) async throws -> MobileTesting_CapabilitiesResponse {
        _ = request

        var requiredCapability = MobileTesting_CapabilityDescriptor()
        requiredCapability.key = "action.tap"
        requiredCapability.tier = .required
        requiredCapability.supported = true

        var queryCapability = MobileTesting_CapabilityDescriptor()
        queryCapability.key = "query.findElements"
        queryCapability.tier = .required
        queryCapability.supported = true

        var response = MobileTesting_CapabilitiesResponse()
        response.capabilities = [requiredCapability, queryCapability]
        return response
    }

    package func endSession(_ request: MobileTesting_EndSessionRequest) async throws
        -> MobileTesting_EndSessionResponse {
        _ = request

        var response = MobileTesting_EndSessionResponse()
        response.ended = true
        return response
    }

    package func tap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func doubleTap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func longPress(_ request: MobileTesting_LongPressRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func tapElement(_ request: MobileTesting_TapElementRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func swipe(_ request: MobileTesting_SwipeRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func scroll(_ request: MobileTesting_ScrollRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func typeText(_ request: MobileTesting_TypeTextRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func clearText(_ request: MobileTesting_ClearTextRequest) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func pressBack(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func pressHome(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }

    package func findElements(_ request: MobileTesting_FindElementsRequest) async throws
        -> MobileTesting_FindElementsResponse {
        var element = MobileTesting_ElementInfo()
        element.id = request.selector.id.isEmpty ? "sample" : request.selector.id
        element.label = request.selector.label.isEmpty ? "sample" : request.selector.label

        var response = MobileTesting_FindElementsResponse()
        response.elements = [element]
        return response
    }

    package func getViewHierarchy(
        _ request: MobileTesting_ViewHierarchyRequest
    ) async throws -> MobileTesting_ViewHierarchyResponse {
        _ = request

        var root = MobileTesting_ViewNode()
        root.id = "root"

        var response = MobileTesting_ViewHierarchyResponse()
        response.root = root
        return response
    }

    package func waitForElement(
        _ request: MobileTesting_WaitForElementRequest
    ) async throws -> MobileTesting_WaitForElementResponse {
        _ = request
        var response = MobileTesting_WaitForElementResponse()
        response.found = true
        return response
    }

    package func isKeyboardVisible(_ request: MobileTesting_Empty) async throws
        -> MobileTesting_KeyboardVisibleResponse {
        _ = request
        var response = MobileTesting_KeyboardVisibleResponse()
        response.visible = false
        return response
    }

    package func takeScreenshot(_ request: MobileTesting_ScreenshotRequest) async throws
        -> MobileTesting_ScreenshotResponse {
        _ = request
        var response = MobileTesting_ScreenshotResponse()
        response.data = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic bytes
        return response
    }

    package func getScreenContext(
        _ request: MobileTesting_ScreenContextRequest
    ) async throws -> MobileTesting_ScreenContextResponse {
        _ = request

        var response = MobileTesting_ScreenContextResponse()
        response.summary = "Empty screen context"
        return response
    }

    package func findByDescription(
        _ request: MobileTesting_FindByDescriptionRequest
    ) async throws -> MobileTesting_FindElementsResponse {
        var element = MobileTesting_ElementInfo()
        element.id = "fixture-home-title"
        element.label = request.description_p.isEmpty ? "Fixture Home" : request.description_p

        var response = MobileTesting_FindElementsResponse()
        response.elements = [element]
        return response
    }

    package func getInteractableElements(
        _ request: MobileTesting_Empty
    ) async throws -> MobileTesting_InteractableElementsResponse {
        _ = request

        var element = MobileTesting_ElementInfo()
        element.id = "fixture-open-details"
        element.label = "Open Details"

        var response = MobileTesting_InteractableElementsResponse()
        response.elements = [element]
        return response
    }

    private func successActionResponse() -> MobileTesting_ActionResponse {
        var response = MobileTesting_ActionResponse()
        response.success = true
        return response
    }
}

// MARK: - LiveCompanionRPCClient

package actor LiveCompanionRPCClient: CompanionRPCClient {
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let client: MobileTesting_CompanionService.Client<HTTP2ClientTransport.Posix>
    private let connectionTask: Task<Void, Never>

    package init(connection: CompanionConnection) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: connection.host, port: connection.port),
            transportSecurity: .plaintext
        )
        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        client = MobileTesting_CompanionService.Client(wrapping: grpcClient)
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

    package func startSession(_ request: MobileTesting_StartSessionRequest) async throws
        -> MobileTesting_StartSessionResponse {
        try await client.startSession(request)
    }

    package func getCapabilities(
        _ request: MobileTesting_CapabilitiesRequest
    ) async throws -> MobileTesting_CapabilitiesResponse {
        try await client.getCapabilities(request)
    }

    package func endSession(_ request: MobileTesting_EndSessionRequest) async throws
        -> MobileTesting_EndSessionResponse {
        try await client.endSession(request)
    }

    package func tap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        try await client.tap(request)
    }

    package func doubleTap(_ request: MobileTesting_TapRequest) async throws -> MobileTesting_ActionResponse {
        try await client.doubleTap(request)
    }

    package func longPress(_ request: MobileTesting_LongPressRequest) async throws -> MobileTesting_ActionResponse {
        try await client.longPress(request)
    }

    package func tapElement(_ request: MobileTesting_TapElementRequest) async throws -> MobileTesting_ActionResponse {
        try await client.tapElement(request)
    }

    package func swipe(_ request: MobileTesting_SwipeRequest) async throws -> MobileTesting_ActionResponse {
        try await client.swipe(request)
    }

    package func scroll(_ request: MobileTesting_ScrollRequest) async throws -> MobileTesting_ActionResponse {
        try await client.scroll(request)
    }

    package func typeText(_ request: MobileTesting_TypeTextRequest) async throws -> MobileTesting_ActionResponse {
        try await client.typeText(request)
    }

    package func clearText(_ request: MobileTesting_ClearTextRequest) async throws -> MobileTesting_ActionResponse {
        try await client.clearText(request)
    }

    package func pressBack(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        try await client.pressBack(request)
    }

    package func pressHome(_ request: MobileTesting_Empty) async throws -> MobileTesting_ActionResponse {
        try await client.pressHome(request)
    }

    package func findElements(_ request: MobileTesting_FindElementsRequest) async throws
        -> MobileTesting_FindElementsResponse {
        try await client.findElements(request)
    }

    package func getViewHierarchy(
        _ request: MobileTesting_ViewHierarchyRequest
    ) async throws -> MobileTesting_ViewHierarchyResponse {
        try await client.getViewHierarchy(request)
    }

    package func waitForElement(
        _ request: MobileTesting_WaitForElementRequest
    ) async throws -> MobileTesting_WaitForElementResponse {
        try await client.waitForElement(request)
    }

    package func isKeyboardVisible(_ request: MobileTesting_Empty) async throws
        -> MobileTesting_KeyboardVisibleResponse {
        try await client.isKeyboardVisible(request)
    }

    package func takeScreenshot(_ request: MobileTesting_ScreenshotRequest) async throws
        -> MobileTesting_ScreenshotResponse {
        try await client.takeScreenshot(request)
    }

    package func getScreenContext(
        _ request: MobileTesting_ScreenContextRequest
    ) async throws -> MobileTesting_ScreenContextResponse {
        try await client.getScreenContext(request)
    }

    package func findByDescription(
        _ request: MobileTesting_FindByDescriptionRequest
    ) async throws -> MobileTesting_FindElementsResponse {
        try await client.findByDescription(request)
    }

    package func getInteractableElements(
        _ request: MobileTesting_Empty
    ) async throws -> MobileTesting_InteractableElementsResponse {
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

    public init(connection: CompanionConnection) {
        self.connection = connection
        rpcClient = InMemoryCompanionRPCClient()
    }

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
        generatedClient: any MobileTesting_CompanionService.ClientProtocol
    ) {
        self.connection = connection
        rpcClient = GeneratedCompanionRPCClient(client: generatedClient)
    }

    // MARK: - Session

    public func startSession() async throws {
        var request = MobileTesting_StartSessionRequest()
        request.requestedSessionID = sessionID ?? UUID().uuidString

        let response = try await rpcClient.startSession(request)
        sessionID = response.sessionID.isEmpty ? request.requestedSessionID : response.sessionID
    }

    public func getCapabilities() async throws -> [CapabilityDescriptor] {
        let response = try await rpcClient.getCapabilities(MobileTesting_CapabilitiesRequest())
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
        var request = MobileTesting_EndSessionRequest()
        request.sessionID = sessionID ?? ""

        _ = try await rpcClient.endSession(request)
        sessionID = nil
    }

    // MARK: - Touch

    public func tap(at point: Point) async throws {
        var request = MobileTesting_TapRequest()
        request.point = point.protoPoint

        let response = try await rpcClient.tap(request)
        try validate(response: response, action: "tap")
    }

    public func doubleTap(at point: Point) async throws {
        var request = MobileTesting_TapRequest()
        request.point = point.protoPoint

        let response = try await rpcClient.doubleTap(request)
        try validate(response: response, action: "doubleTap")
    }

    public func longPress(at point: Point, duration: Duration) async throws {
        var request = MobileTesting_LongPressRequest()
        request.point = point.protoPoint
        var dur = MobileTesting_Duration()
        dur.milliseconds = Int32(duration.milliseconds)
        request.duration = dur

        let response = try await rpcClient.longPress(request)
        try validate(response: response, action: "longPress")
    }

    public func tapElement(_ selector: ElementSelector, appID: String? = nil, candidateBundleIDs: [String] = []) async throws {
        var request = MobileTesting_TapElementRequest()
        request.selector = selector.protoSelector
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.tapElement(request)
        try validate(response: response, action: "tapElement")
    }

    // MARK: - Gestures

    public func swipe(from: Point, to: Point, duration: Duration) async throws {
        var request = MobileTesting_SwipeRequest()
        request.from = from.protoPoint
        request.to = to.protoPoint
        var dur = MobileTesting_Duration()
        dur.milliseconds = Int32(duration.milliseconds)
        request.duration = dur

        let response = try await rpcClient.swipe(request)
        try validate(response: response, action: "swipe")
    }

    public func scroll(direction: Direction, distance: Double) async throws {
        var request = MobileTesting_ScrollRequest()
        request.direction = direction.protoDirection
        request.distance = Float(distance)

        let response = try await rpcClient.scroll(request)
        try validate(response: response, action: "scroll")
    }

    // MARK: - Text

    public func typeText(_ text: String) async throws {
        var request = MobileTesting_TypeTextRequest()
        request.text = text

        let response = try await rpcClient.typeText(request)
        try validate(response: response, action: "typeText")
    }

    public func clearText(characterCount: Int?) async throws {
        var request = MobileTesting_ClearTextRequest()
        request.characterCount = Int32(characterCount ?? 0)

        let response = try await rpcClient.clearText(request)
        try validate(response: response, action: "clearText")
    }

    // MARK: - Navigation

    public func pressBack() async throws {
        let response = try await rpcClient.pressBack(MobileTesting_Empty())
        try validate(response: response, action: "pressBack")
    }

    public func pressHome() async throws {
        let response = try await rpcClient.pressHome(MobileTesting_Empty())
        try validate(response: response, action: "pressHome")
    }

    // MARK: - Accessibility

    public func findElements(_ selector: ElementSelector, appID: String? = nil, candidateBundleIDs: [String] = []) async throws
        -> [ElementInfo] {
        var request = MobileTesting_FindElementsRequest()
        request.selector = selector.protoSelector
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.findElements(request)
        return response.elements.map(\.coreElementInfo)
    }

    public func getViewHierarchy(appID: String? = nil, candidateBundleIDs: [String] = []) async throws -> ViewNode {
        var request = MobileTesting_ViewHierarchyRequest()
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
        var request = MobileTesting_WaitForElementRequest()
        request.selector = selector.protoSelector
        var dur = MobileTesting_Duration()
        dur.milliseconds = Int32(timeout.milliseconds)
        request.timeout = dur
        request.appID = appID ?? ""
        request.candidateBundleIds = candidateBundleIDs

        let response = try await rpcClient.waitForElement(request)
        if !response.found {
            throw MobileTestingError.timeout(operation: "waitForElement", duration: timeout)
        }
    }

    public func isKeyboardVisible() async throws -> Bool {
        let response = try await rpcClient.isKeyboardVisible(MobileTesting_Empty())
        return response.visible
    }

    // MARK: - Capture

    public func takeScreenshot() async throws -> ScreenshotData {
        let response = try await rpcClient.takeScreenshot(MobileTesting_ScreenshotRequest())
        return ScreenshotData(bytes: [UInt8](response.data))
    }

    // MARK: - AI

    public func getScreenContext() async throws -> ScreenContext {
        var request = MobileTesting_ScreenContextRequest()
        request.format = "summary"

        let response = try await rpcClient.getScreenContext(request)
        return ScreenContext(summary: response.summary.nonEmpty ?? "Empty screen context")
    }

    public func getInteractableElements() async throws -> [ElementInfo] {
        let response = try await rpcClient.getInteractableElements(MobileTesting_Empty())
        return response.elements.map(\.coreElementInfo)
    }

    public func findByDescription(_ description: String) async throws -> [ElementInfo] {
        var request = MobileTesting_FindByDescriptionRequest()
        request.description_p = description
        let response = try await rpcClient.findByDescription(request)
        return response.elements.map(\.coreElementInfo)
    }

    // MARK: - Lifecycle

    public func shutdown() async {
        await rpcClient.shutdown()
    }

    // MARK: - Private

    private func validate(response: MobileTesting_ActionResponse, action: String) throws {
        guard response.success else {
            let reason = response.message.nonEmpty ?? "unknown"
            throw MobileTestingError.unsupportedCapability(key: "action.\(action)", reason: reason)
        }
    }
}

// MARK: - Proto Conversions

private extension CapabilityTier {
    static func from(_ tier: MobileTesting_CapabilityTier) -> Self {
        switch tier {
        case .required:
            .required
        case .optional, .unspecified, .UNRECOGNIZED:
            .optional
        }
    }
}

private extension MobileTesting_CapabilityTier {
    var coreTier: CapabilityTier {
        .from(self)
    }
}

private extension Point {
    var protoPoint: MobileTesting_Point {
        var point = MobileTesting_Point()
        point.x = x
        point.y = y
        return point
    }
}

private extension Direction {
    var protoDirection: MobileTesting_Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

private extension MobileTesting_ElementInfo {
    var coreElementInfo: ElementInfo {
        ElementInfo(
            id: id.nonEmpty ?? "",
            label: label.nonEmpty ?? "",
            value: value.nonEmpty,
            type: ElementType(rawValue: type.lowercased()),
            frame: hasFrame ? frame.coreRect : nil,
            isEnabled: isEnabled,
            isVisible: isVisible
        )
    }
}

private extension MobileTesting_ViewNode {
    var coreViewNode: ViewNode {
        ViewNode(
            id: id.nonEmpty ?? "",
            label: label.nonEmpty ?? "",
            value: value.nonEmpty,
            type: ElementType(rawValue: type.lowercased()),
            frame: hasFrame ? frame.coreRect : nil,
            isEnabled: isEnabled,
            isVisible: isVisible,
            children: children.map(\.coreViewNode)
        )
    }
}

private extension MobileTesting_Rect {
    var coreRect: Rect {
        Rect(x: x, y: y, width: width, height: height)
    }
}

private extension ElementSelector {
    var protoSelector: MobileTesting_ElementSelector {
        var selector = MobileTesting_ElementSelector()

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
