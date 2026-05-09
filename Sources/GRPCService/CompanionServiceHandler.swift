import CompanionProtocol
import Foundation
import GRPCCore
import MobileTestingCore
import Protos

package actor CompanionServiceHandler: MobileTesting_CompanionService.SimpleServiceProtocol {
    private let companion: any CompanionClient
    private let screenshotProvider: (any ScreenCapture)?

    package init(companion: any CompanionClient, screenshotProvider: (any ScreenCapture)? = nil) {
        self.companion = companion
        self.screenshotProvider = screenshotProvider
    }

    // MARK: - Session

    package func startSession(
        request: MobileTesting_StartSessionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_StartSessionResponse {
        try await companion.startSession()

        let sessionID = request.requestedSessionID.nonEmpty ?? UUID().uuidString

        var response = MobileTesting_StartSessionResponse()
        response.sessionID = sessionID
        return response
    }

    package func getCapabilities(
        request _: MobileTesting_CapabilitiesRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_CapabilitiesResponse {
        let capabilities = try await companion.getCapabilities()

        var response = MobileTesting_CapabilitiesResponse()
        response.capabilities = capabilities.map(\.protoCapabilityDescriptor)
        return response
    }

    package func endSession(
        request _: MobileTesting_EndSessionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_EndSessionResponse {
        try await companion.endSession()

        var response = MobileTesting_EndSessionResponse()
        response.ended = true
        return response
    }

    // MARK: - Touch

    package func tap(
        request: MobileTesting_TapRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        try await companion.tap(at: request.point.corePoint)
        return actionResponse(success: true)
    }

    package func doubleTap(
        request: MobileTesting_TapRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        try await companion.doubleTap(at: request.point.corePoint)
        return actionResponse(success: true)
    }

    package func longPress(
        request: MobileTesting_LongPressRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        try await companion.longPress(at: request.point.corePoint, duration: duration)
        return actionResponse(success: true)
    }

    package func tapElement(
        request: MobileTesting_TapElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let appID = request.appID.isEmpty ? nil : request.appID
        try await companion.tapElement(
            request.selector.coreSelector,
            appID: appID,
            candidateBundleIDs: request.candidateBundleIds
        )
        return actionResponse(success: true)
    }

    // MARK: - Gestures

    package func swipe(
        request: MobileTesting_SwipeRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        try await companion.swipe(from: request.from.corePoint, to: request.to.corePoint, duration: duration)
        return actionResponse(success: true)
    }

    package func swipeInDirection(
        request: MobileTesting_SwipeDirectionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let distance = request.distance > 0 ? Double(request.distance) : 300
        let duration = request.durationMs > 0 ? Duration(milliseconds: Int(request.durationMs)) : Duration(milliseconds: 400)
        let element: ElementSelector? = request.hasSelector ? ElementSelector(
            id: request.selector.id.isEmpty ? nil : request.selector.id,
            label: request.selector.label.isEmpty ? nil : request.selector.label,
            containsText: request.selector.containsText.isEmpty ? nil : request.selector.containsText
        ) : nil
        try await companion.swipeInDirection(request.direction.coreDirection, distance: distance, duration: duration, element: element)
        return actionResponse(success: true)
    }

    package func scroll(
        request: MobileTesting_ScrollRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        try await companion.scroll(direction: request.direction.coreDirection, distance: Double(request.distance))
        return actionResponse(success: true)
    }

    package func scrollToElement(
        request: MobileTesting_ScrollToElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // Scroll in direction until element is found, up to maxScrolls times.
        // Clamp the request value: an unbounded loop here is a remote-DoS vector
        // (one find + one scroll per iteration, both gRPC round-trips).
        let direction = request.direction.coreDirection
        let selector = request.selector.coreSelector
        let requested = Int(request.maxScrolls)
        let maxScrolls = max(0, min(requested, Self.maxScrollAttempts))

        for _ in 0 ..< maxScrolls {
            try Task.checkCancellation()
            let elements = try await companion.findElements(selector)
            if !elements.isEmpty {
                return actionResponse(success: true)
            }
            try await companion.scroll(direction: direction, distance: 300)
        }

        return actionResponse(success: false, message: "Element not found after \(maxScrolls) scrolls")
    }

    /// Hard cap on `scrollToElement` iterations. Caller-supplied values above
    /// this are clamped to prevent indefinite work on the companion.
    private static let maxScrollAttempts = 100

    package func pinch(
        request: MobileTesting_PinchRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // Pinch delegates to companion — not yet in CompanionClient, return not implemented
        actionResponse(success: false, message: "pinch not implemented")
    }

    package func drag(
        request: MobileTesting_DragRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // Drag is a long press + swipe
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        try await companion.swipe(from: request.from.corePoint, to: request.to.corePoint, duration: duration)
        return actionResponse(success: true)
    }

    // MARK: - Text

    package func typeText(
        request: MobileTesting_TypeTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        try await companion.typeText(request.text)
        return actionResponse(success: true)
    }

    package func clearText(
        request: MobileTesting_ClearTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let count = request.characterCount > 0 ? Int(request.characterCount) : nil
        try await companion.clearText(characterCount: count)
        return actionResponse(success: true)
    }

    package func setText(
        request: MobileTesting_SetTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // Clear then type — companion doesn't have a direct setText yet
        try await companion.clearText(characterCount: nil)
        try await companion.typeText(request.text)
        return actionResponse(success: true)
    }

    // MARK: - Navigation

    package func pressBack(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        try await companion.pressBack()
        return actionResponse(success: true)
    }

    package func pressHome(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // pressHome is typically host-executed, but companion can handle on Android
        actionResponse(success: false, message: "pressHome not implemented via companion")
    }

    // MARK: - Accessibility

    package func getViewHierarchy(
        request: MobileTesting_ViewHierarchyRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ViewHierarchyResponse {
        let appID = request.appID.isEmpty ? nil : request.appID
        let hierarchy = try await companion.getViewHierarchy(
            appID: appID,
            candidateBundleIDs: request.candidateBundleIds
        )

        var response = MobileTesting_ViewHierarchyResponse()
        response.root = hierarchy.protoViewNode
        return response
    }

    package func findElements(
        request: MobileTesting_FindElementsRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_FindElementsResponse {
        let appID = request.appID.isEmpty ? nil : request.appID
        let elements = try await companion.findElements(
            request.selector.coreSelector,
            appID: appID,
            candidateBundleIDs: request.candidateBundleIds
        )

        var response = MobileTesting_FindElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    package func waitForElement(
        request: MobileTesting_WaitForElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_WaitForElementResponse {
        let timeout = Duration(milliseconds: Int(request.timeout.milliseconds))
        let appID = request.appID.isEmpty ? nil : request.appID
        do {
            try await companion.waitForElement(
                request.selector.coreSelector,
                timeout: timeout,
                appID: appID,
                candidateBundleIDs: request.candidateBundleIds
            )
            var response = MobileTesting_WaitForElementResponse()
            response.found = true
            return response
        } catch {
            var response = MobileTesting_WaitForElementResponse()
            response.found = false
            return response
        }
    }

    package func isKeyboardVisible(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_KeyboardVisibleResponse {
        let visible = try await companion.isKeyboardVisible()
        var response = MobileTesting_KeyboardVisibleResponse()
        response.visible = visible
        return response
    }

    // MARK: - AI Context

    package func getScreenContext(
        request _: MobileTesting_ScreenContextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ScreenContextResponse {
        let context = try await companion.getScreenContext()

        var response = MobileTesting_ScreenContextResponse()
        response.summary = context.summary
        return response
    }

    package func findByDescription(
        request: MobileTesting_FindByDescriptionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_FindElementsResponse {
        let elements = try await companion.findByDescription(request.description_p)

        var response = MobileTesting_FindElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    package func getInteractableElements(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_InteractableElementsResponse {
        let elements = try await companion.getInteractableElements()

        var response = MobileTesting_InteractableElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    // MARK: - Capture

    package func takeScreenshot(
        request _: MobileTesting_ScreenshotRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ScreenshotResponse {
        var response = MobileTesting_ScreenshotResponse()

        if let screenshotProvider {
            let screenshot = try await screenshotProvider.takeScreenshot(format: .png)
            response.data = Data(screenshot.bytes)
        }

        return response
    }

    // MARK: - Helpers

    private func actionResponse(success: Bool, message: String = "") -> MobileTesting_ActionResponse {
        var response = MobileTesting_ActionResponse()
        response.success = success
        response.message = message
        return response
    }
}

// MARK: - Proto Conversions

private extension CapabilityDescriptor {
    var protoCapabilityDescriptor: MobileTesting_CapabilityDescriptor {
        var descriptor = MobileTesting_CapabilityDescriptor()
        descriptor.key = key
        descriptor.tier = switch tier {
        case .required:
            .required
        case .optional:
            .optional
        }
        descriptor.supported = supported
        descriptor.reasonIfUnsupported = reasonIfUnsupported ?? ""
        return descriptor
    }
}

private extension MobileTesting_Point {
    var corePoint: Point {
        Point(x: x, y: y)
    }
}

private extension MobileTesting_Direction {
    var coreDirection: Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .unspecified, .UNRECOGNIZED: .down
        }
    }
}

private extension ElementInfo {
    var protoElementInfo: MobileTesting_ElementInfo {
        var element = MobileTesting_ElementInfo()
        element.id = id
        element.label = label
        return element
    }
}

private extension ViewNode {
    var protoViewNode: MobileTesting_ViewNode {
        var node = MobileTesting_ViewNode()
        node.id = id
        node.label = label
        if let value { node.value = value }
        if let type { node.type = type.rawValue }
        if let frame {
            var rect = MobileTesting_Rect()
            rect.x = frame.x
            rect.y = frame.y
            rect.width = frame.width
            rect.height = frame.height
            node.frame = rect
        }
        node.isEnabled = isEnabled
        node.isVisible = isVisible
        node.children = children.map(\.protoViewNode)
        return node
    }
}

private extension MobileTesting_ElementSelector {
    var coreSelector: ElementSelector {
        let parent: ParentSelector? = hasParentSelector ? .selector(parentSelector.coreSelector) : nil

        return ElementSelector(
            id: id.nonEmpty,
            label: label.nonEmpty,
            containsText: containsText.nonEmpty,
            description: description_p.nonEmpty,
            parentSelector: parent
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
