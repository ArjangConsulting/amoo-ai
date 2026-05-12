import MobileTestingCore
import XCTest

private struct UnimplementedTouch: TouchActions {}
private struct UnimplementedGesture: GestureActions {}
private struct UnimplementedText: TextActions {}
private struct UnimplementedNavigation: NavigationActions {}
private struct UnimplementedDeviceDriver: DeviceDriver {}
private struct UnimplementedCapture: ScreenCapture {}
private struct UnimplementedAccessibility: AccessibilityProvider {}
private struct UnimplementedConfigurator: DeviceConfigurator {}
private struct UnimplementedAIContext: AIContextProvider {}

final class MobileTestingCoreTests: XCTestCase {
    private func assertNotImplemented(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected notImplemented error", file: file, line: line)
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .notImplemented(expected), file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testElementSelectorSupportsParentSelector() {
        let parent = ElementSelector(id: "parent")
        let selector = ElementSelector(id: "child", parentSelector: .selector(parent))
        XCTAssertEqual(selector.id, "child")
    }

    func testDefaultTouchImplementationThrows() async {
        let action = UnimplementedTouch()
        do {
            try await action.tap(at: Point(x: 1, y: 2))
            XCTFail("Expected notImplemented error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .notImplemented("tap"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemainingDefaultTouchImplementationsThrow() async {
        let action = UnimplementedTouch()
        await assertNotImplemented("doubleTap") {
            try await action.doubleTap(at: Point(x: 5, y: 6))
        }
        await assertNotImplemented("longPress") {
            try await action.longPress(at: Point(x: 7, y: 8), duration: .defaultLongPress)
        }
        await assertNotImplemented("tapElement") {
            try await action.tapElement(.init(id: "login"))
        }
    }

    func testDefaultGestureImplementationThrows() async {
        do {
            try await UnimplementedGesture().swipe(
                from: Point(x: 0, y: 0),
                to: Point(x: 1, y: 1),
                duration: Duration(milliseconds: 50)
            )
            XCTFail("Expected notImplemented error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .notImplemented("swipe"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemainingDefaultGestureImplementationsThrow() async {
        let gesture = UnimplementedGesture()
        await assertNotImplemented("swipe(direction:element:)") {
            try await gesture.swipe(direction: .left, distance: 100, duration: .defaultSwipe)
        }
        await assertNotImplemented("scroll") {
            try await gesture.scroll(direction: .down, distance: 200)
        }
        await assertNotImplemented("scrollToElement") {
            try await gesture.scrollToElement(.init(label: "Continue"), direction: .up, maxScrolls: 3)
        }
        await assertNotImplemented("pinch") {
            try await gesture.pinch(center: Point(x: 20, y: 30), scale: 0.5, velocity: 1.2)
        }
        await assertNotImplemented("drag") {
            try await gesture.drag(
                from: Point(x: 0, y: 0),
                to: Point(x: 10, y: 10),
                duration: .defaultSwipe,
                holdDuration: .defaultLongPress
            )
        }
    }

    func testDefaultTextAndNavigationImplementationsThrow() async {
        do {
            try await UnimplementedText().typeText("hello")
            XCTFail("Expected notImplemented error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .notImplemented("typeText"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await UnimplementedNavigation().pressBack()
            XCTFail("Expected notImplemented error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .notImplemented("pressBack"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemainingDefaultTextAndNavigationImplementationsThrow() async {
        let text = UnimplementedText()
        let navigation = UnimplementedNavigation()

        await assertNotImplemented("clearText") {
            try await text.clearText(characterCount: 4)
        }
        await assertNotImplemented("setText") {
            try await text.setText(.init(id: "username"), text: "mani")
        }
        await assertNotImplemented("pressHome") {
            try await navigation.pressHome()
        }
        await assertNotImplemented("openURL") {
            try await navigation.openURL("https://example.com")
        }
    }

    func testDefaultDriverAndProviderImplementationsThrow() async {
        await assertNotImplemented("boot") {
            try await UnimplementedDeviceDriver().boot()
        }
        await assertNotImplemented("shutdown") {
            try await UnimplementedDeviceDriver().shutdown()
        }
        await assertNotImplemented("takeScreenshot") {
            _ = try await UnimplementedCapture().takeScreenshot(format: .png)
        }
        await assertNotImplemented("findElements") {
            _ = try await UnimplementedAccessibility().findElements(.init(id: "missing"))
        }
        await assertNotImplemented("getViewHierarchy") {
            _ = try await UnimplementedAccessibility().getViewHierarchy()
        }
        await assertNotImplemented("setPermission") {
            try await UnimplementedConfigurator().setPermission(
                .init(appID: "com.example", permission: "camera", granted: true)
            )
        }
        await assertNotImplemented("getScreenContext") {
            _ = try await UnimplementedAIContext().getScreenContext()
        }
    }

    func testRemainingDefaultDriverAndProviderImplementationsThrow() async {
        let driver = UnimplementedDeviceDriver()
        let capture = UnimplementedCapture()
        let accessibility = UnimplementedAccessibility()
        let configurator = UnimplementedConfigurator()
        let aiContext = UnimplementedAIContext()
        let appManagement = UnimplementedAppManagement()

        await assertNotImplemented("deviceInfo") {
            _ = try await driver.deviceInfo()
        }
        await assertNotImplemented("installApp") {
            try await appManagement.installApp(path: "/tmp/App.app")
        }
        await assertNotImplemented("launchApp") {
            try await appManagement.launchApp(appID: "com.example", arguments: [], environment: [:])
        }
        await assertNotImplemented("terminateApp") {
            try await appManagement.terminateApp(appID: "com.example")
        }
        await assertNotImplemented("uninstallApp") {
            try await appManagement.uninstallApp(appID: "com.example")
        }
        await assertNotImplemented("listApps") {
            _ = try await appManagement.listApps()
        }
        await assertNotImplemented("appState") {
            _ = try await appManagement.appState(appID: "com.example")
        }
        await assertNotImplemented("startRecording") {
            _ = try await capture.startRecording()
        }
        await assertNotImplemented("stopRecording") {
            _ = try await capture.stopRecording(sessionID: "session-1")
        }
        await assertNotImplemented("elementExists") {
            _ = try await accessibility.elementExists(.init(id: "missing"))
        }
        await assertNotImplemented("waitForElement") {
            try await accessibility.waitForElement(.init(id: "missing"), timeout: .defaultSwipe)
        }
        await assertNotImplemented("waitForElementToDisappear") {
            try await accessibility.waitForElementToDisappear(.init(id: "missing"), timeout: .defaultSwipe)
        }
        await assertNotImplemented("isKeyboardVisible") {
            _ = try await accessibility.isKeyboardVisible()
        }
        await assertNotImplemented("setLocation") {
            try await configurator.setLocation(latitude: 37.0, longitude: -122.0)
        }
        await assertNotImplemented("clearLocation") {
            try await configurator.clearLocation()
        }
        await assertNotImplemented("setAppearance") {
            try await configurator.setAppearance(.light)
        }
        await assertNotImplemented("getInteractableElements") {
            _ = try await aiContext.getInteractableElements()
        }
        await assertNotImplemented("findByDescription") {
            _ = try await aiContext.findByDescription("settings")
        }
    }

    func testCoreTypesInitializers() {
        XCTAssertEqual(Point(x: 3, y: 4), Point(x: 3, y: 4))
        XCTAssertEqual(Duration(milliseconds: 250), Duration(milliseconds: 250))
        XCTAssertEqual(ScreenshotData(bytes: [1, 2]), ScreenshotData(bytes: [1, 2]))
        XCTAssertEqual(ViewNode(id: "root"), ViewNode(id: "root"))
        XCTAssertEqual(
            ElementInfo(id: "button", label: "Continue"),
            ElementInfo(id: "button", label: "Continue")
        )
        XCTAssertEqual(ScreenContext(summary: "summary"), ScreenContext(summary: "summary"))
        XCTAssertEqual(
            PermissionChange(appID: "com.example", permission: "camera", granted: false),
            PermissionChange(appID: "com.example", permission: "camera", granted: false)
        )
    }

    func testAdditionalCoreTypesAndEnums() {
        XCTAssertEqual(Duration.defaultSwipe, Duration(milliseconds: 300))
        XCTAssertEqual(Duration.defaultLongPress, Duration(milliseconds: 1000))
        XCTAssertEqual(Direction.left.rawValue, "left")
        XCTAssertEqual(Rect(x: 1, y: 2, width: 3, height: 4), Rect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(ImageFormat.jpeg.rawValue, "jpeg")
        XCTAssertEqual(RecordingSession(id: "rec", deviceID: "booted"), RecordingSession(id: "rec", deviceID: "booted"))
        XCTAssertEqual(ElementType.switchControl.rawValue, "switch")
        XCTAssertEqual(
            AppInfo(appID: "com.example", name: "Example", version: "1.0"),
            AppInfo(appID: "com.example", name: "Example", version: "1.0")
        )
        XCTAssertEqual(AppState.notInstalled.rawValue, "notInstalled")
        XCTAssertEqual(Appearance.dark.rawValue, "dark")
        XCTAssertEqual(
            DeviceInfo(id: "1", name: "Phone", platform: .ios, osVersion: "18.0", state: .booted),
            DeviceInfo(id: "1", name: "Phone", platform: .ios, osVersion: "18.0", state: .booted)
        )
        XCTAssertEqual(Platform.android.rawValue, "android")
        XCTAssertEqual(DeviceState.shutdown.rawValue, "shutdown")
    }
}

private struct UnimplementedAppManagement: AppManagement {}
