import Foundation
import GRPCCore
import XCTest

// swiftformat:disable wrapMultilineStatementBraces

/// gRPC service provider implementing the CompanionService proto contract.
/// Routes each RPC to the appropriate handler via XCUITestBridge.
///
/// Uses grpc-swift v2 async APIs. All handler calls are async because
/// XCUITestBridge is @MainActor and requires main thread dispatch.
actor CompanionServiceProvider: MobileTesting_CompanionService.SimpleServiceProtocol {
    private let touch: TouchHandler
    private let gesture: GestureHandler
    private let text: TextHandler
    private let accessibility: AccessibilityHandler
    private var sessionID: String?

    init(
        touch: TouchHandler,
        gesture: GestureHandler,
        text: TextHandler,
        accessibility: AccessibilityHandler
    ) {
        self.touch = touch
        self.gesture = gesture
        self.text = text
        self.accessibility = accessibility
    }

    // MARK: - Session

    func startSession(
        request: MobileTesting_StartSessionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_StartSessionResponse {
        let id = request.requestedSessionID.isEmpty ? UUID().uuidString : request.requestedSessionID
        sessionID = id

        var response = MobileTesting_StartSessionResponse()
        response.sessionID = id
        return response
    }

    func getCapabilities(
        request _: MobileTesting_CapabilitiesRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_CapabilitiesResponse {
        let capabilities: [(String, MobileTesting_CapabilityTier)] = [
            ("action.tap", .required),
            ("action.doubleTap", .required),
            ("action.longPress", .required),
            ("action.swipe", .required),
            ("action.scroll", .required),
            ("action.swipeInDirection", .required),
            ("action.typeText", .required),
            ("action.clearText", .required),
            ("action.pressBack", .required),
            ("query.findElements", .required),
            ("query.getViewHierarchy", .required),
            ("query.isKeyboardVisible", .required),
            ("capture.screenshot", .required),
            ("ai.screenContext", .optional)
        ]

        var response = MobileTesting_CapabilitiesResponse()
        response.capabilities = capabilities.map { key, tier in
            var cap = MobileTesting_CapabilityDescriptor()
            cap.key = key
            cap.tier = tier
            cap.supported = true
            return cap
        }
        return response
    }

    func endSession(
        request _: MobileTesting_EndSessionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_EndSessionResponse {
        sessionID = nil
        var response = MobileTesting_EndSessionResponse()
        response.ended = true
        return response
    }

    // MARK: - Touch

    func tap(
        request: MobileTesting_TapRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await touch.tap(x: request.point.x, y: request.point.y)
        return successResponse()
    }

    func doubleTap(
        request: MobileTesting_TapRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await touch.doubleTap(x: request.point.x, y: request.point.y)
        return successResponse()
    }

    func longPress(
        request: MobileTesting_LongPressRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await touch.longPress(x: request.point.x, y: request.point.y, durationMs: Int(request.duration.milliseconds))
        return successResponse()
    }

    func tapElement(
        request: MobileTesting_TapElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        let bundleID = request.appID.isEmpty ? nil : request.appID
        let tapped = await touch.tapElement(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: request.candidateBundleIds
        )
        return tapped ? successResponse() : failResponse("Element not found or not hittable")
    }

    // MARK: - Gestures

    func swipe(
        request: MobileTesting_SwipeRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await gesture.swipe(
            fromX: request.from.x, fromY: request.from.y,
            toX: request.to.x, toY: request.to.y,
            durationMs: Int(request.duration.milliseconds)
        )
        return successResponse()
    }

    func swipeInDirection(
        request: MobileTesting_SwipeDirectionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let direction: ScrollDirection = switch request.direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: .down
        }
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        await gesture.swipeInDirection(
            direction: direction,
            id: id,
            label: label,
            containsText: containsText
        )
        return successResponse()
    }

    func scroll(
        request: MobileTesting_ScrollRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let direction: ScrollDirection = switch request.direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: .down
        }
        await gesture.scroll(direction: direction, distance: Double(request.distance))
        return successResponse()
    }

    func scrollToElement(
        request: MobileTesting_ScrollToElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let direction: ScrollDirection = switch request.direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: .down
        }
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let maxScrolls = Int(request.maxScrolls)

        for _ in 0 ..< maxScrolls {
            let elements = await accessibility.findElements(id: id, label: label, containsText: nil)
            if !elements.isEmpty {
                return successResponse()
            }
            await gesture.scroll(direction: direction, distance: 300)
        }
        return failResponse("Element not found after \(maxScrolls) scrolls")
    }

    func pinch(
        request _: MobileTesting_PinchRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        failResponse("pinch not yet implemented")
    }

    func drag(
        request: MobileTesting_DragRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        // `hold_duration` is a message field, so an explicit zero (caller wants no dwell)
        // is distinguishable from an omitted field (caller has no opinion).
        let holdMs = request.hasHoldDuration
            ? Int(request.holdDuration.milliseconds)
            : Self.defaultDragHoldMilliseconds
        await gesture.drag(
            fromX: request.from.x, fromY: request.from.y,
            toX: request.to.x, toY: request.to.y,
            durationMs: Int(request.duration.milliseconds),
            holdMs: holdMs
        )
        return successResponse()
    }

    /// Hold applied at the drag origin when the caller doesn't specify one. Matches the
    /// iOS long-press threshold, so an unqualified drag picks the target up rather than
    /// degrading into a swipe.
    private static let defaultDragHoldMilliseconds = 500

    // MARK: - Text

    func typeText(
        request: MobileTesting_TypeTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await text.typeText(request.text)
        return successResponse()
    }

    func clearText(
        request: MobileTesting_ClearTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let count = request.characterCount > 0 ? Int(request.characterCount) : nil
        await text.clearText(characterCount: count)
        return successResponse()
    }

    func setText(
        request: MobileTesting_SetTextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await text.clearText(characterCount: nil)
        await text.typeText(request.text)
        return successResponse()
    }

    // MARK: - Navigation

    func pressBack(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let tapped = await touch.tapElement(id: nil, label: "Back")
        return tapped ? successResponse() : failResponse("Back button not found")
    }

    func pressHome(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        await MainActor.run { XCUIDevice.shared.press(.home) }
        return successResponse()
    }

    // MARK: - Accessibility

    func getViewHierarchy(
        request: MobileTesting_ViewHierarchyRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ViewHierarchyResponse {
        let bundleID = request.appID.isEmpty ? nil : request.appID
        let candidates = request.candidateBundleIds
        let hierarchy = await accessibility.getViewHierarchy(bundleID: bundleID, candidateBundleIDs: candidates)
        var response = MobileTesting_ViewHierarchyResponse()
        response.root = hierarchy.toProto()
        return response
    }

    func findElements(
        request: MobileTesting_FindElementsRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_FindElementsResponse {
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        let bundleID = request.appID.isEmpty ? nil : request.appID

        let elements = await accessibility.findElements(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: request.candidateBundleIds
        )
        var response = MobileTesting_FindElementsResponse()
        response.elements = elements.map { $0.toProto() }
        return response
    }

    func waitForElement(
        request: MobileTesting_WaitForElementRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_WaitForElementResponse {
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        let timeoutMs = Int(request.timeout.milliseconds)
        let intervalMs = 200
        var elapsed = 0
        let bundleID = request.appID.isEmpty ? nil : request.appID

        while elapsed < timeoutMs {
            let elements = await accessibility.findElements(
                id: id,
                label: label,
                containsText: containsText,
                bundleID: bundleID,
                candidateBundleIDs: request.candidateBundleIds
            )
            if !elements.isEmpty {
                var response = MobileTesting_WaitForElementResponse()
                response.found = true
                return response
            }
            try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            elapsed += intervalMs
        }

        var response = MobileTesting_WaitForElementResponse()
        response.found = false
        return response
    }

    func isKeyboardVisible(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_KeyboardVisibleResponse {
        var response = MobileTesting_KeyboardVisibleResponse()
        response.visible = await accessibility.isKeyboardVisible()
        return response
    }

    // MARK: - AI Context

    func getScreenContext(
        request _: MobileTesting_ScreenContextRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ScreenContextResponse {
        let hierarchy = await accessibility.getViewHierarchy()
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: nil)
        let interactable = elements.filter { $0.isEnabled && $0.isVisible }

        var response = MobileTesting_ScreenContextResponse()
        response.summary = summarizeScreen(hierarchy: hierarchy, elements: elements, interactable: interactable)
        return response
    }

    func findByDescription(
        request: MobileTesting_FindByDescriptionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_FindElementsResponse {
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: request.description_p)
        var response = MobileTesting_FindElementsResponse()
        response.elements = elements.map { $0.toProto() }
        return response
    }

    func getInteractableElements(
        request _: MobileTesting_Empty,
        context _: ServerContext
    ) async throws -> MobileTesting_InteractableElementsResponse {
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: nil)
        let interactable = elements.filter { $0.isEnabled && $0.isVisible }

        var response = MobileTesting_InteractableElementsResponse()
        response.elements = interactable.map { $0.toProto() }
        return response
    }

    // MARK: - Capture

    func takeScreenshot(
        request _: MobileTesting_ScreenshotRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ScreenshotResponse {
        let data = await accessibility.takeScreenshot()
        var response = MobileTesting_ScreenshotResponse()
        response.data = data
        return response
    }

    // MARK: - Helpers

    private func successResponse() -> MobileTesting_ActionResponse {
        var response = MobileTesting_ActionResponse()
        response.success = true
        return response
    }

    private func failResponse(_ message: String) -> MobileTesting_ActionResponse {
        var response = MobileTesting_ActionResponse()
        response.success = false
        response.message = message
        return response
    }

    private func summarizeScreen(
        hierarchy: ViewNodeSnapshot,
        elements: [ElementSnapshot],
        interactable: [ElementSnapshot]
    ) -> String {
        let title = inferredScreenTitle(from: elements, hierarchy: hierarchy)
        let primaryActions = appRelevantInteractables(interactable)
            .prefix(3)
            .compactMap { preferredText(label: $0.label, id: normalizedIdentifier($0.id)) }
        let textHighlights = elements
            .filter { $0.isVisible && $0.type == "staticText" }
            .prefix(4)
            .compactMap { preferredText(label: $0.label, id: nil) }
        let formFields = elements
            .filter { $0.isVisible && $0.type == "textField" }
            .prefix(3)
            .compactMap { preferredText(label: $0.label, id: normalizedIdentifier($0.id)) }

        let parts = [
            title.map { "title=\($0)" },
            !primaryActions.isEmpty ? "primary_actions=\(primaryActions.joined(separator: ", "))" : nil,
            !formFields.isEmpty ? "form_fields=\(formFields.joined(separator: ", "))" : nil,
            !textHighlights.isEmpty ? "visible_text=\(textHighlights.joined(separator: ", "))" : nil,
            "interactable=\(appRelevantInteractables(interactable).count)",
            "visible_elements=\(elements.filter(\.isVisible).count)",
            hierarchy.id.isEmpty ? nil : "root=\(hierarchy.id)"
        ].compactMap(\.self)

        return parts.joined(separator: " | ")
    }

    private func inferredScreenTitle(from elements: [ElementSnapshot], hierarchy: ViewNodeSnapshot) -> String? {
        if let navigationTitle = hierarchy.children.first(where: {
            $0.type == "navigationBar" && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.label, !navigationTitle.isEmpty {
            return navigationTitle
        }

        if let firstTitle = elements.first(where: {
            $0.isVisible && $0.type == "staticText" && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.label, !firstTitle.isEmpty {
            return firstTitle
        }

        if !hierarchy.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hierarchy.label
        }

        return nil
    }

    private func appRelevantInteractables(_ elements: [ElementSnapshot]) -> [ElementSnapshot] {
        elements.filter {
            $0.isVisible && $0.isEnabled && !isLikelySystemElement($0)
        }
    }

    private func isLikelySystemElement(_ element: ElementSnapshot) -> Bool {
        let raw = "\(element.id) \(element.label) \(element.value)".lowercased()
        let systemTerms = [
            "wifi", "wi-fi", "battery", "signal", "carrier", "clock", "time", "status bar", "cellular"
        ]
        return systemTerms.contains(where: { raw.contains($0) }) || raw.hasPrefix("status") || raw.contains("system")
    }

    private func preferredText(label: String, id: String?) -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            return trimmedLabel
        }
        guard let id else { return nil }
        return id.isEmpty ? nil : id
    }

    private func normalizedIdentifier(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        let genericTerms = ["button", "view", "cell", "image", "label", "text"]
        if genericTerms.contains(where: { lowered == $0 || lowered.hasPrefix($0) && lowered.count <= $0.count + 2 }) {
            return nil
        }

        return trimmed
    }
}

// MARK: - Proto Conversions

extension ElementSnapshot {
    func toProto() -> MobileTesting_ElementInfo {
        var element = MobileTesting_ElementInfo()
        element.id = id
        element.label = label
        element.value = value
        element.type = type
        element.isEnabled = isEnabled
        element.isVisible = isVisible

        var rect = MobileTesting_Rect()
        rect.x = frame.origin.x
        rect.y = frame.origin.y
        rect.width = frame.size.width
        rect.height = frame.size.height
        element.frame = rect

        return element
    }
}

extension ViewNodeSnapshot {
    func toProto() -> MobileTesting_ViewNode {
        var node = MobileTesting_ViewNode()
        node.id = id
        node.label = label
        node.type = type
        node.isEnabled = isEnabled
        node.isVisible = isVisible

        var rect = MobileTesting_Rect()
        rect.x = frame.origin.x
        rect.y = frame.origin.y
        rect.width = frame.size.width
        rect.height = frame.size.height
        node.frame = rect

        node.children = children.map { $0.toProto() }
        return node
    }
}

// swiftformat:enable wrapMultilineStatementBraces
