import AmooCore
import CompanionProtocol
import Foundation
import GRPCCore
import Protos

package extension CompanionServiceHandler {
    // MARK: - Text

    func typeText(
        request: Amoo_TypeTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.typeText(request.text)
        return actionResponse(success: true)
    }

    func clearText(
        request: Amoo_ClearTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let count = request.characterCount > 0 ? Int(request.characterCount) : nil
        try await companion.clearText(characterCount: count)
        return actionResponse(success: true)
    }

    func setText(
        request: Amoo_SetTextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        // Clear then type — companion doesn't have a direct setText yet
        try await companion.clearText(characterCount: nil)
        try await companion.typeText(request.text)
        return actionResponse(success: true)
    }

    // MARK: - Navigation

    func pressBack(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.pressBack()
        return actionResponse(success: true)
    }

    func pressHome(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        // pressHome is typically host-executed, but companion can handle on Android
        actionResponse(success: false, message: "pressHome not implemented via companion")
    }

    // MARK: - Accessibility

    func getViewHierarchy(
        request: Amoo_ViewHierarchyRequest,
        context _: ServerContext
    ) async throws -> Amoo_ViewHierarchyResponse {
        let appID = request.appID.isEmpty ? nil : request.appID
        let hierarchy = try await companion.getViewHierarchy(
            appID: appID,
            candidateBundleIDs: request.candidateBundleIds
        )

        var response = Amoo_ViewHierarchyResponse()
        response.root = hierarchy.protoViewNode
        return response
    }

    func findElements(
        request: Amoo_FindElementsRequest,
        context _: ServerContext
    ) async throws -> Amoo_FindElementsResponse {
        let appID = request.appID.isEmpty ? nil : request.appID
        let elements = try await companion.findElements(
            request.selector.coreSelector,
            appID: appID,
            candidateBundleIDs: request.candidateBundleIds
        )

        var response = Amoo_FindElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    func waitForElement(
        request: Amoo_WaitForElementRequest,
        context _: ServerContext
    ) async throws -> Amoo_WaitForElementResponse {
        let timeout = Duration(milliseconds: Int(request.timeout.milliseconds))
        let appID = request.appID.isEmpty ? nil : request.appID
        do {
            try await companion.waitForElement(
                request.selector.coreSelector,
                timeout: timeout,
                appID: appID,
                candidateBundleIDs: request.candidateBundleIds
            )
            var response = Amoo_WaitForElementResponse()
            response.found = true
            return response
        } catch {
            var response = Amoo_WaitForElementResponse()
            response.found = false
            return response
        }
    }

    func isKeyboardVisible(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_KeyboardVisibleResponse {
        let visible = try await companion.isKeyboardVisible()
        var response = Amoo_KeyboardVisibleResponse()
        response.visible = visible
        return response
    }

    // MARK: - Target app

    func getCurrentApp(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_CurrentAppResponse {
        let info = try await companion.currentApp()
        var response = Amoo_CurrentAppResponse()
        response.bundleID = info.bundleID
        response.targetBundleID = info.targetBundleID
        return response
    }

    func setTargetApp(
        request: Amoo_SetTargetAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await companion.setTargetApp(bundleID: request.bundleID.nonEmpty)
        var response = Amoo_ActionResponse()
        response.success = true
        return response
    }

    func getAppState(
        request: Amoo_GetAppStateRequest,
        context _: ServerContext
    ) async throws -> Amoo_GetAppStateResponse {
        var response = Amoo_GetAppStateResponse()
        response.state = try await companion.appState(appID: request.appID)
        return response
    }

    func getScreenInfo(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ScreenInfoResponse {
        let info = try await companion.screenInfo()
        var response = Amoo_ScreenInfoResponse()
        response.widthPoints = info.widthPoints
        response.heightPoints = info.heightPoints
        response.widthPixels = info.widthPixels
        response.heightPixels = info.heightPixels
        response.scale = info.scale
        return response
    }

    // MARK: - AI Context

    func getScreenContext(
        request _: Amoo_ScreenContextRequest,
        context _: ServerContext
    ) async throws -> Amoo_ScreenContextResponse {
        let context = try await companion.getScreenContext()

        var response = Amoo_ScreenContextResponse()
        response.summary = context.summary
        return response
    }

    func findByDescription(
        request: Amoo_FindByDescriptionRequest,
        context _: ServerContext
    ) async throws -> Amoo_FindElementsResponse {
        let elements = try await companion.findByDescription(request.description_p)

        var response = Amoo_FindElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    func getInteractableElements(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_InteractableElementsResponse {
        let elements = try await companion.getInteractableElements()

        var response = Amoo_InteractableElementsResponse()
        response.elements = elements.map(\.protoElementInfo)
        return response
    }

    // MARK: - Capture

    func takeScreenshot(
        request _: Amoo_ScreenshotRequest,
        context _: ServerContext
    ) async throws -> Amoo_ScreenshotResponse {
        var response = Amoo_ScreenshotResponse()

        if let screenshotProvider {
            let screenshot = try await screenshotProvider.takeScreenshot(format: .png)
            response.data = Data(screenshot.bytes)
        }

        return response
    }
}
