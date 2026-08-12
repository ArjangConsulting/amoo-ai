import AmooCore
import GRPCCore
import Protos

package protocol HostDeviceControlling: Sendable {
    func installApp(path: String) async throws
    func launchApp(appID: String, arguments: [String]) async throws
    func terminateApp(appID: String) async throws
    func uninstallApp(appID: String) async throws
    func setPermission(_ change: PermissionChange) async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
    func setAppearance(_ appearance: Appearance) async throws
    func openURL(_ url: String) async throws
}

package struct NoopHostDeviceController: HostDeviceControlling {
    package init() {}

    package func installApp(path _: String) async throws {}
    package func launchApp(appID _: String, arguments _: [String]) async throws {}
    package func terminateApp(appID _: String) async throws {}
    package func uninstallApp(appID _: String) async throws {}
    package func setPermission(_: PermissionChange) async throws {}
    package func setLocation(latitude _: Double, longitude _: Double) async throws {}
    package func clearLocation() async throws {}
    package func setAppearance(_: Appearance) async throws {}
    package func openURL(_: String) async throws {}
}

package actor HostDeviceServiceHandler: Amoo_HostDeviceService.SimpleServiceProtocol {
    private let controller: any HostDeviceControlling

    package init(controller: any HostDeviceControlling = NoopHostDeviceController()) {
        self.controller = controller
    }

    package func installApp(
        request: Amoo_InstallAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.installApp(path: request.path)
        return actionResponse()
    }

    package func launchApp(
        request: Amoo_LaunchAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.launchApp(appID: request.appID, arguments: request.arguments)
        return actionResponse()
    }

    package func terminateApp(
        request: Amoo_TerminateAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.terminateApp(appID: request.appID)
        return actionResponse()
    }

    package func uninstallApp(
        request: Amoo_UninstallAppRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.uninstallApp(appID: request.appID)
        return actionResponse()
    }

    package func setPermission(
        request: Amoo_SetPermissionRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let change = PermissionChange(
            appID: request.appID,
            permission: request.permission,
            granted: request.granted
        )
        try await controller.setPermission(change)
        return actionResponse()
    }

    package func setLocation(
        request: Amoo_SetLocationRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.setLocation(latitude: request.latitude, longitude: request.longitude)
        return actionResponse()
    }

    package func clearLocation(
        request _: Amoo_Empty,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.clearLocation()
        return actionResponse()
    }

    package func setAppearance(
        request: Amoo_SetAppearanceRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        let appearance: Appearance = request.appearance == "dark" ? .dark : .light
        try await controller.setAppearance(appearance)
        return actionResponse()
    }

    package func openURL(
        request: Amoo_OpenURLRequest,
        context _: ServerContext
    ) async throws -> Amoo_ActionResponse {
        try await controller.openURL(request.url)
        return actionResponse()
    }

    private func actionResponse() -> Amoo_ActionResponse {
        var response = Amoo_ActionResponse()
        response.success = true
        response.message = "ok"
        return response
    }
}
