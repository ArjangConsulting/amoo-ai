import Foundation
import GRPCCore
import XCTest

// swiftformat:disable wrapMultilineStatementBraces

/// gRPC service provider implementing the CompanionService proto contract.
/// Routes each RPC to the appropriate handler via XCUITestBridge.
///
/// Uses grpc-swift v2 async APIs. All handler calls are async because
/// XCUITestBridge is @MainActor and requires main thread dispatch.
actor CompanionServiceProvider: Amoo_CompanionService.SimpleServiceProtocol {
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
        request: Amoo_StartSessionRequest,
        context _: ServerContext
    ) async throws -> Amoo_StartSessionResponse {
        let id = request.requestedSessionID.isEmpty ? UUID().uuidString : request.requestedSessionID
        sessionID = id

        var response = Amoo_StartSessionResponse()
        response.sessionID = id
        return response
    }

    func getCapabilities(
        request _: Amoo_CapabilitiesRequest,
        context _: ServerContext
    ) async throws -> Amoo_CapabilitiesResponse {
        let capabilities: [(String, Amoo_CapabilityTier)] = [
            ("protocol.amoo.v1", .required),
            ("action.tap", .required),
            ("action.doubleTap", .required),
            ("action.longPress", .required),
            ("action.swipe", .required),
            ("action.scroll", .required),
            ("action.swipeInDirection", .required),
            ("action.typeText", .required),
            ("action.clearText", .required),
            ("action.setText", .required),
            ("action.pressBack", .required),
            ("query.findElements", .required),
            ("query.getViewHierarchy", .required),
            ("query.isKeyboardVisible", .required),
            ("query.currentApp", .required),
            ("query.screenInfo", .required),
            ("action.setTargetApp", .required),
            ("capture.screenshot", .required),
            ("ai.screenContext", .optional)
        ]

        var response = Amoo_CapabilitiesResponse()
        response.capabilities = capabilities.map { key, tier in
            var cap = Amoo_CapabilityDescriptor()
            cap.key = key
            cap.tier = tier
            cap.supported = true
            return cap
        }
        return response
    }

    func endSession(
        request _: Amoo_EndSessionRequest,
        context _: ServerContext
    ) async throws -> Amoo_EndSessionResponse {
        sessionID = nil
        var response = Amoo_EndSessionResponse()
        response.ended = true
        return response
    }

    // MARK: - Touch

    func tap(
        request: Amoo_TapRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await touch.tap(x: request.point.x, y: request.point.y)
        return successResponse()
    }

    func doubleTap(
        request: Amoo_TapRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await touch.doubleTap(x: request.point.x, y: request.point.y)
        return successResponse()
    }

    func longPress(
        request: Amoo_LongPressRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await touch.longPress(x: request.point.x, y: request.point.y, durationMs: Int(request.duration.milliseconds))
        return successResponse()
    }

    func tapElement(
        request: Amoo_TapElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request: Amoo_SwipeRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await gesture.swipe(
            fromX: request.from.x, fromY: request.from.y,
            toX: request.to.x, toY: request.to.y,
            durationMs: Int(request.duration.milliseconds)
        )
        return successResponse()
    }

    func swipeInDirection(
        request: Amoo_SwipeDirectionRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        let swiped = await gesture.swipeInDirection(
            direction: direction,
            id: id,
            label: label,
            containsText: containsText
        )
        return swiped ? successResponse() : failResponse("Element not found for swipe")
    }

    func scroll(
        request: Amoo_ScrollRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request: Amoo_ScrollToElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request _: Amoo_PinchRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        failResponse("pinch not yet implemented")
    }

    func drag(
        request: Amoo_DragRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request: Amoo_TypeTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await text.typeText(request.text)
        return successResponse()
    }

    func clearText(
        request: Amoo_ClearTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let count = request.characterCount > 0 ? Int(request.characterCount) : nil
        await text.clearText(characterCount: count)
        return successResponse()
    }

    func setText(
        request: Amoo_SetTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let selector = request.selector
        let set = await text.setText(
            id: selector.id.nonEmpty,
            label: selector.label.nonEmpty,
            containsText: selector.containsText.nonEmpty,
            text: request.text,
            bundleID: request.appID.nonEmpty,
            candidateBundleIDs: request.candidateBundleIds
        )
        return set ? successResponse() : failResponse("text field not found")
    }

    // MARK: - Navigation

    func pressBack(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let tapped = await touch.tapElement(id: nil, label: "Back")
        return tapped ? successResponse() : failResponse("Back button not found")
    }

    func pressHome(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await MainActor.run { XCUIDevice.shared.press(.home) }
        return successResponse()
    }

    // MARK: - Accessibility

    func getViewHierarchy(
        request: Amoo_ViewHierarchyRequest,
        context _: ServerContext
    ) async throws -> Amoo_ViewHierarchyResponse {
        let bundleID = request.appID.isEmpty ? nil : request.appID
        let candidates = request.candidateBundleIds
        let hierarchy = await accessibility.getViewHierarchy(bundleID: bundleID, candidateBundleIDs: candidates)
        var response = Amoo_ViewHierarchyResponse()
        response.root = hierarchy.toProto()
        return response
    }

    func findElements(
        request: Amoo_FindElementsRequest,
        context _: ServerContext
    ) async throws -> Amoo_FindElementsResponse {
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        let bundleID = request.appID.isEmpty ? nil : request.appID

        let elements = await accessibility.findElements(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: request.candidateBundleIds,
            labeledOnly: request.selector.labeledOnly
        )
        var response = Amoo_FindElementsResponse()
        response.elements = elements.map { $0.toProto() }
        return response
    }

    func waitForElement(
        request: Amoo_WaitForElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_WaitForElementResponse {
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
                var response = Amoo_WaitForElementResponse()
                response.found = true
                return response
            }
            try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            elapsed += intervalMs
        }

        var response = Amoo_WaitForElementResponse()
        response.found = false
        return response
    }

    func isKeyboardVisible(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_KeyboardVisibleResponse {
        var response = Amoo_KeyboardVisibleResponse()
        response.visible = await accessibility.isKeyboardVisible()
        return response
    }

    // MARK: - Target app

    /// Which app a gesture would land in right now, without the caller paying for a screenshot
    /// to work it out.
    func getCurrentApp(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_CurrentAppResponse {
        var response = Amoo_CurrentAppResponse()
        response.bundleID = await accessibility.currentAppBundleID() ?? ""
        response.targetBundleID = await accessibility.targetAppBundleID() ?? ""
        return response
    }

    func setTargetApp(
        request: Amoo_SetTargetAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        await accessibility.setTargetApp(
            bundleID: request.bundleID.isEmpty ? nil : request.bundleID
        )
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }

    func getAppState(
        request: Amoo_GetAppStateRequest,
        context _: ServerContext
    ) async throws -> Amoo_GetAppStateResponse {
        var response = Amoo_GetAppStateResponse()
        response.state = await accessibility.appState(appID: request.appID)
        return response
    }

    // MARK: - AI Context

    func getScreenContext(
        request _: Amoo_ScreenContextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ScreenContextResponse {
        let hierarchy = await accessibility.getViewHierarchy()
        // Labeled only: the summary describes a screen by what its elements are called, and its
        // element count is the baseline `assert_screen_changed` compares against. Neither gains
        // anything from frame-only entries.
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: nil, labeledOnly: true)
        let interactable = elements.filter { $0.isEnabled && $0.isVisible }

        var response = Amoo_ScreenContextResponse()
        response.summary = summarizeScreen(hierarchy: hierarchy, elements: elements, interactable: interactable)
        return response
    }

    func findByDescription(
        request: Amoo_FindByDescriptionRequest,
        context _: ServerContext
    ) async throws -> Amoo_FindElementsResponse {
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: request.description_p)
        var response = Amoo_FindElementsResponse()
        response.elements = elements.map { $0.toProto() }
        return response
    }

    func getInteractableElements(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_InteractableElementsResponse {
        // Unlabeled elements included, deliberately: this feeds the accessibility reports, and
        // an element with neither identifier nor label is the finding they exist to produce.
        // UX-001 (MissingAccessibilityLabelRule) selects on exactly `label.isEmpty && id.isEmpty`,
        // so filtering those out here leaves the rule unable to fire at all, and
        // highlight_a11y_issues with nothing to draw a red box around.
        let elements = await accessibility.findElements(id: nil, label: nil, containsText: nil)
        let interactable = elements.filter { $0.isEnabled && $0.isVisible }

        var response = Amoo_InteractableElementsResponse()
        response.elements = interactable.map { $0.toProto() }
        return response
    }

    // MARK: - Capture

    func takeScreenshot(
        request _: Amoo_ScreenshotRequest,
        context _: ServerContext
    ) async throws -> Amoo_ScreenshotResponse {
        let data = await accessibility.takeScreenshot()
        var response = Amoo_ScreenshotResponse()
        response.data = data
        response.screen = await screenInfoResponse()
        return response
    }

    func getScreenInfo(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ScreenInfoResponse {
        await screenInfoResponse()
    }

    private func screenInfoResponse() async -> Amoo_ScreenInfoResponse {
        let info = await accessibility.screenInfo()
        var response = Amoo_ScreenInfoResponse()
        response.widthPoints = Double(info.points.width)
        response.heightPoints = Double(info.points.height)
        response.widthPixels = Double(info.pixels.width)
        response.heightPixels = Double(info.pixels.height)
        response.scale = info.scale
        return response
    }

    // MARK: - Helpers

    private func successResponse() -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }

    private func failResponse(_ message: String) -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
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

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Proto Conversions

extension ElementSnapshot {
    func toProto() -> Amoo_ElementInfo {
        var element = Amoo_ElementInfo()
        element.id = id
        element.label = label
        element.value = value
        element.type = type
        element.isSecureTextEntry = isSecureTextEntry
        element.isEnabled = isEnabled
        element.isVisible = isVisible

        var rect = Amoo_Rect()
        rect.x = frame.origin.x
        rect.y = frame.origin.y
        rect.width = frame.size.width
        rect.height = frame.size.height
        element.frame = rect

        var hitPoint = Amoo_Point()
        hitPoint.x = self.hitPoint.x
        hitPoint.y = self.hitPoint.y
        element.hitPoint = hitPoint

        return element
    }
}

extension ViewNodeSnapshot {
    func toProto() -> Amoo_ViewNode {
        var node = Amoo_ViewNode()
        node.id = id
        node.label = label
        node.value = value
        node.isSecureTextEntry = isSecureTextEntry
        node.type = type
        node.isEnabled = isEnabled
        node.isVisible = isVisible

        var rect = Amoo_Rect()
        rect.x = frame.origin.x
        rect.y = frame.origin.y
        rect.width = frame.size.width
        rect.height = frame.size.height
        node.frame = rect

        var hitPoint = Amoo_Point()
        hitPoint.x = self.hitPoint.x
        hitPoint.y = self.hitPoint.y
        node.hitPoint = hitPoint

        node.children = children.map { $0.toProto() }
        return node
    }
}

// swiftformat:enable wrapMultilineStatementBraces
