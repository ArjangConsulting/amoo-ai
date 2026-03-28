import AuditEngine
import CompanionProtocol
import GRPCCore
import GRPCService
import MobileTestingCore
import Protos
import XCTest

final class GRPCServiceTests: XCTestCase {
    func testHealth() {
        XCTAssertEqual(DeviceService().health(), "ok")
    }

    func testRunAudit() async throws {
        let service = DeviceService()
        let engine = AuditEngine(rules: [DebugBuildExposureRule(), MissingStableIdentifierRule()])
        let input = AuditInput(
            appID: "com.example.app",
            screenContext: .init(summary: "debug banner"),
            hierarchy: .init(id: "root"),
            interactableElements: [
                ElementInfo(id: "", label: "Submit", type: .button)
            ]
        )

        let report = try await service.runAudit(engine, input: input)
        XCTAssertEqual(report.appID, "com.example.app")
        XCTAssertEqual(report.findings.count, 2)
    }

    func testCompanionServiceHandlerMapsCoreContracts() async throws {
        let companion = MockCompanionClient()
        let screenshots = MockScreenshotProvider()
        let handler = CompanionServiceHandler(companion: companion, screenshotProvider: screenshots)
        let context = makeContext()

        var startRequest = MobileTesting_StartSessionRequest()
        startRequest.requestedSessionID = "test-session"
        let startResponse = try await handler.startSession(request: startRequest, context: context)
        XCTAssertEqual(startResponse.sessionID, "test-session")

        let capabilityResponse = try await handler.getCapabilities(
            request: MobileTesting_CapabilitiesRequest(),
            context: context
        )
        XCTAssertEqual(capabilityResponse.capabilities.first?.key, "action.tap")

        var tapRequest = MobileTesting_TapRequest()
        var point = MobileTesting_Point()
        point.x = 10
        point.y = 20
        tapRequest.point = point
        let tapResponse = try await handler.tap(request: tapRequest, context: context)
        XCTAssertTrue(tapResponse.success)

        var findRequest = MobileTesting_FindElementsRequest()
        findRequest.selector = MobileTesting_ElementSelector()
        findRequest.selector.id = "login"
        findRequest.appID = "com.example.login"
        findRequest.candidateBundleIds = ["com.example.login", "com.apple.springboard"]
        let findResponse = try await handler.findElements(request: findRequest, context: context)
        XCTAssertEqual(findResponse.elements.first?.id, "login")
        let findContext = await companion.lastFindElementsContext
        XCTAssertEqual(findContext?.appID, "com.example.login")
        XCTAssertEqual(findContext?.candidateBundleIDs, ["com.example.login", "com.apple.springboard"])

        var tapElementRequest = MobileTesting_TapElementRequest()
        tapElementRequest.selector.label = "Continue"
        tapElementRequest.appID = "com.example.login"
        tapElementRequest.candidateBundleIds = ["com.example.login"]
        let tapElementResponse = try await handler.tapElement(request: tapElementRequest, context: context)
        XCTAssertTrue(tapElementResponse.success)
        let tapContext = await companion.lastTapElementContext
        XCTAssertEqual(tapContext?.appID, "com.example.login")
        XCTAssertEqual(tapContext?.candidateBundleIDs, ["com.example.login"])

        let hierarchyResponse = try await handler.getViewHierarchy(
            request: MobileTesting_ViewHierarchyRequest(),
            context: context
        )
        XCTAssertEqual(hierarchyResponse.root.id, "root")

        let screenContextResponse = try await handler.getScreenContext(
            request: MobileTesting_ScreenContextRequest(),
            context: context
        )
        XCTAssertEqual(screenContextResponse.summary, "Mock screen context")

        let screenshotResponse = try await handler.takeScreenshot(
            request: MobileTesting_ScreenshotRequest(),
            context: context
        )
        XCTAssertEqual(Array(screenshotResponse.data), [1, 2, 3])

        let endResponse = try await handler.endSession(
            request: MobileTesting_EndSessionRequest(),
            context: context
        )
        XCTAssertTrue(endResponse.ended)
    }

    func testNewCompanionServiceRPCs() async throws {
        let companion = MockCompanionClient()
        let handler = CompanionServiceHandler(companion: companion)
        let context = makeContext()

        // DoubleTap
        var doubleTapReq = MobileTesting_TapRequest()
        doubleTapReq.point = MobileTesting_Point()
        doubleTapReq.point.x = 5
        doubleTapReq.point.y = 10
        let doubleTapResp = try await handler.doubleTap(request: doubleTapReq, context: context)
        XCTAssertTrue(doubleTapResp.success)

        // Scroll
        var scrollReq = MobileTesting_ScrollRequest()
        scrollReq.direction = .down
        scrollReq.distance = 300
        let scrollResp = try await handler.scroll(request: scrollReq, context: context)
        XCTAssertTrue(scrollResp.success)

        // ClearText
        var clearReq = MobileTesting_ClearTextRequest()
        clearReq.characterCount = 5
        let clearResp = try await handler.clearText(request: clearReq, context: context)
        XCTAssertTrue(clearResp.success)

        // IsKeyboardVisible
        let kbResp = try await handler.isKeyboardVisible(request: MobileTesting_Empty(), context: context)
        XCTAssertFalse(kbResp.visible)

        var waitReq = MobileTesting_WaitForElementRequest()
        waitReq.selector.label = "Welcome"
        waitReq.appID = "com.example.fixture"
        waitReq.candidateBundleIds = ["com.example.fixture"]
        waitReq.timeout.milliseconds = 500
        let waitResp = try await handler.waitForElement(request: waitReq, context: context)
        XCTAssertTrue(waitResp.found)
        let waitContext = await companion.lastWaitForElementContext
        XCTAssertEqual(waitContext?.appID, "com.example.fixture")
        XCTAssertEqual(waitContext?.candidateBundleIDs, ["com.example.fixture"])
    }

    func testHostDeviceServiceHandlerDelegatesToController() async throws {
        let controller = MockHostController()
        let handler = HostDeviceServiceHandler(controller: controller)
        let context = makeContext()

        var installRequest = MobileTesting_InstallAppRequest()
        installRequest.path = "/tmp/app.apk"
        let installResponse = try await handler.installApp(request: installRequest, context: context)
        XCTAssertTrue(installResponse.success)

        var launchRequest = MobileTesting_LaunchAppRequest()
        launchRequest.appID = "com.example.app"
        launchRequest.arguments = ["--uitest"]
        let launchResponse = try await handler.launchApp(request: launchRequest, context: context)
        XCTAssertTrue(launchResponse.success)

        var terminateRequest = MobileTesting_TerminateAppRequest()
        terminateRequest.appID = "com.example.app"
        let terminateResponse = try await handler.terminateApp(request: terminateRequest, context: context)
        XCTAssertTrue(terminateResponse.success)

        var uninstallRequest = MobileTesting_UninstallAppRequest()
        uninstallRequest.appID = "com.example.app"
        let uninstallResponse = try await handler.uninstallApp(request: uninstallRequest, context: context)
        XCTAssertTrue(uninstallResponse.success)

        var permissionRequest = MobileTesting_SetPermissionRequest()
        permissionRequest.appID = "com.example.app"
        permissionRequest.permission = "camera"
        permissionRequest.granted = true
        let permissionResponse = try await handler.setPermission(request: permissionRequest, context: context)
        XCTAssertTrue(permissionResponse.success)

        var locationRequest = MobileTesting_SetLocationRequest()
        locationRequest.latitude = 37.77
        locationRequest.longitude = -122.42
        let locationResponse = try await handler.setLocation(request: locationRequest, context: context)
        XCTAssertTrue(locationResponse.success)

        let clearLocResponse = try await handler.clearLocation(request: MobileTesting_Empty(), context: context)
        XCTAssertTrue(clearLocResponse.success)

        var appearanceRequest = MobileTesting_SetAppearanceRequest()
        appearanceRequest.appearance = "dark"
        let appearanceResponse = try await handler.setAppearance(request: appearanceRequest, context: context)
        XCTAssertTrue(appearanceResponse.success)

        var urlRequest = MobileTesting_OpenURLRequest()
        urlRequest.url = "myapp://test"
        let urlResponse = try await handler.openURL(request: urlRequest, context: context)
        XCTAssertTrue(urlResponse.success)

        let calls = await controller.calls
        XCTAssertEqual(
            calls,
            [
                "install:/tmp/app.apk",
                "launch:com.example.app:--uitest",
                "terminate:com.example.app",
                "uninstall:com.example.app",
                "permission:com.example.app:camera:true",
                "location:37.77,-122.42",
                "clearLocation",
                "appearance:dark",
                "openURL:myapp://test"
            ]
        )
    }

    private func makeContext() -> ServerContext {
        ServerContext(
            descriptor: MethodDescriptor(fullyQualifiedService: "tests.grpc", method: "TestMethod"),
            remotePeer: "in-process:test-client",
            localPeer: "in-process:test-server",
            cancellation: .init()
        )
    }
}

private actor MockCompanionClient: CompanionClient {
    // swiftlint:disable large_tuple
    var lastTapElementContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    var lastFindElementsContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    var lastWaitForElementContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    // swiftlint:enable large_tuple

    func startSession() async throws {}

    func getCapabilities() async throws -> [CapabilityDescriptor] {
        [CapabilityDescriptor(key: "action.tap", tier: .required, supported: true)]
    }

    func endSession() async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws {
        lastTapElementContext = (selector, appID, candidateBundleIDs)
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}

    func pressBack() async throws {}

    func findElements(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws
        -> [ElementInfo] {
        lastFindElementsContext = (selector, appID, candidateBundleIDs)
        return [ElementInfo(id: selector.id ?? "sample", label: selector.label ?? "sample")]
    }

    func getViewHierarchy(appID _: String?, candidateBundleIDs _: [String]) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Mock screen context")
    }

    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func waitForElement(
        _ selector: ElementSelector,
        timeout _: Duration,
        appID: String?,
        candidateBundleIDs: [String]
    ) async throws {
        lastWaitForElementContext = (selector, appID, candidateBundleIDs)
    }
}

private struct MockScreenshotProvider: ScreenCapture {
    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [1, 2, 3])
    }
}

private actor MockHostController: HostDeviceControlling {
    var calls: [String] = []

    func installApp(path: String) async throws {
        calls.append("install:\(path)")
    }

    func launchApp(appID: String, arguments: [String]) async throws {
        calls.append("launch:\(appID):\(arguments.joined(separator: ","))")
    }

    func terminateApp(appID: String) async throws {
        calls.append("terminate:\(appID)")
    }

    func uninstallApp(appID: String) async throws {
        calls.append("uninstall:\(appID)")
    }

    func setPermission(_ change: PermissionChange) async throws {
        calls.append("permission:\(change.appID):\(change.permission):\(change.granted)")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        calls.append("location:\(latitude),\(longitude)")
    }

    func clearLocation() async throws {
        calls.append("clearLocation")
    }

    func setAppearance(_ appearance: Appearance) async throws {
        calls.append("appearance:\(appearance.rawValue)")
    }

    func openURL(_ url: String) async throws {
        calls.append("openURL:\(url)")
    }
}
