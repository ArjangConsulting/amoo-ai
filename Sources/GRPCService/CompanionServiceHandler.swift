import AmooCore
import CompanionProtocol
import Foundation
import GRPCCore
import Protos

package actor CompanionServiceHandler: Amoo_CompanionService.SimpleServiceProtocol {
    let companion: any CompanionClient
    let screenshotProvider: (any ScreenCapture)?

    package init(companion: any CompanionClient, screenshotProvider: (any ScreenCapture)? = nil) {
        self.companion = companion
        self.screenshotProvider = screenshotProvider
    }

    // MARK: - Session

    package func startSession(
        request: Amoo_StartSessionRequest,
        context _: ServerContext
    ) async throws -> Amoo_StartSessionResponse {
        try await companion.startSession()

        let sessionID = request.requestedSessionID.nonEmpty ?? UUID().uuidString

        var response = Amoo_StartSessionResponse()
        response.sessionID = sessionID
        return response
    }

    package func getCapabilities(
        request _: Amoo_CapabilitiesRequest,
        context _: ServerContext
    ) async throws -> Amoo_CapabilitiesResponse {
        let capabilities = try await companion.getCapabilities()

        // Forward the wrapped companion's own answer rather than asserting one. This handler used
        // to unconditionally claim "protocol.amoo.v1 supported" regardless of what the real
        // companion reported, which made it a lie for any caller checking compatibility through
        // this proxy, and would have collided with the real companion's own entry now that both
        // companion apps report this key themselves.
        var response = Amoo_CapabilitiesResponse()
        response.capabilities = capabilities.map(\.protoCapabilityDescriptor)
        return response
    }

    package func endSession(
        request _: Amoo_EndSessionRequest,
        context _: ServerContext
    ) async throws -> Amoo_EndSessionResponse {
        try await companion.endSession()

        var response = Amoo_EndSessionResponse()
        response.ended = true
        return response
    }

    // MARK: - Touch

    package func tap(
        request: Amoo_TapRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.tap(at: request.point.corePoint)
        return actionResponse(success: true)
    }

    package func doubleTap(
        request: Amoo_TapRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.doubleTap(at: request.point.corePoint)
        return actionResponse(success: true)
    }

    package func longPress(
        request: Amoo_LongPressRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        try await companion.longPress(at: request.point.corePoint, duration: duration)
        return actionResponse(success: true)
    }

    package func tapElement(
        request: Amoo_TapElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request: Amoo_SwipeRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        try await companion.swipe(from: request.from.corePoint, to: request.to.corePoint, duration: duration)
        return actionResponse(success: true)
    }

    package func swipeInDirection(
        request: Amoo_SwipeDirectionRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let distance = request.distance > 0 ? Double(request.distance) : 300
        let duration = request
            .durationMs > 0 ? Duration(milliseconds: Int(request.durationMs)) : Duration(milliseconds: 400)
        let element: ElementSelector? = request.hasSelector ? request.selector.coreSelector : nil
        try await companion.swipeInDirection(
            request.direction.coreDirection,
            distance: distance,
            duration: duration,
            element: element
        )
        return actionResponse(success: true)
    }

    package func scroll(
        request: Amoo_ScrollRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.scroll(direction: request.direction.coreDirection, distance: Double(request.distance))
        return actionResponse(success: true)
    }

    package func scrollToElement(
        request: Amoo_ScrollToElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
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
        request: Amoo_PinchRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        // Pinch delegates to companion — not yet in CompanionClient, return not implemented
        actionResponse(success: false, message: "pinch not implemented")
    }

    /// Hold applied at the drag origin when the caller doesn't specify one. Matches the
    /// platform long-press threshold, so an unqualified drag actually picks the target up
    /// rather than degrading into a swipe.
    package static let defaultDragHoldMilliseconds = 500

    package func drag(
        request: Amoo_DragRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let duration = Duration(milliseconds: Int(request.duration.milliseconds))
        // `hold_duration` is a message field, so an explicit zero (caller wants no dwell)
        // is distinguishable from an omitted field (caller has no opinion).
        let holdMilliseconds = request.hasHoldDuration
            ? Int(request.holdDuration.milliseconds)
            : Self.defaultDragHoldMilliseconds
        try await companion.drag(
            from: request.from.corePoint,
            to: request.to.corePoint,
            duration: duration,
            holdDuration: Duration(milliseconds: holdMilliseconds)
        )
        return actionResponse(success: true)
    }

    // MARK: - Helpers

    func actionResponse(success: Bool, message: String = "") -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
        response.success = success
        response.message = message
        return response
    }
}
