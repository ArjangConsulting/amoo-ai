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
}
