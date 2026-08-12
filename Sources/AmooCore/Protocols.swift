// MARK: - Action Protocols

public protocol TouchActions: Sendable {
    func tap(at point: Point) async throws
    func doubleTap(at point: Point) async throws
    func longPress(at point: Point, duration: Duration) async throws
    func tapElement(_ selector: ElementSelector) async throws
}

public protocol GestureActions: Sendable {
    func swipe(from: Point, to: Point, duration: Duration) async throws
    func swipe(direction: Direction, distance: Double, duration: Duration) async throws
    func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws
    func scroll(direction: Direction, distance: Double) async throws
    func scrollToElement(_ selector: ElementSelector, direction: Direction, maxScrolls: Int) async throws
    func pinch(center: Point, scale: Double, velocity: Double) async throws
    func drag(from: Point, to: Point, duration: Duration, holdDuration: Duration) async throws
}

public protocol TextActions: Sendable {
    func typeText(_ text: String) async throws
    func clearText(characterCount: Int?) async throws
    func setText(_ selector: ElementSelector, text: String) async throws
}

public protocol NavigationActions: Sendable {
    func pressBack() async throws
    func pressHome() async throws
    func openURL(_ url: String) async throws
}

public protocol Actions: TouchActions, GestureActions, TextActions, NavigationActions, Sendable {}

// MARK: - Device Lifecycle

public protocol DeviceDriver: Sendable {
    func boot() async throws
    func shutdown() async throws
    func deviceInfo() async throws -> DeviceInfo
}

// MARK: - App Management

public protocol AppManagement: Sendable {
    func installApp(path: String) async throws
    func launchApp(appID: String, arguments: [String], environment: [String: String]) async throws
    func terminateApp(appID: String) async throws
    func uninstallApp(appID: String) async throws
    func listApps() async throws -> [AppInfo]
    func appState(appID: String) async throws -> AppState
}

// MARK: - Screen Capture

public protocol ScreenCapture: Sendable {
    /// Captures a screenshot of the current screen.
    ///
    /// `format` is a request, not a guarantee — drivers may ignore it and capture
    /// in a different encoding (e.g. Android always produces PNG). Callers must
    /// consult `ScreenshotData.format` for the encoding actually returned.
    func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData
    func startRecording() async throws -> RecordingSession
    func stopRecording(sessionID: String) async throws -> String
}

// MARK: - Accessibility

public protocol AccessibilityProvider: Sendable {
    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo]
    func getViewHierarchy() async throws -> ViewNode
    func elementExists(_ selector: ElementSelector) async throws -> Bool
    func waitForElement(_ selector: ElementSelector, timeout: Duration) async throws
    func waitForElementToDisappear(_ selector: ElementSelector, timeout: Duration) async throws
    func isKeyboardVisible() async throws -> Bool
}

// MARK: - Configuration

public protocol DeviceConfigurator: Sendable {
    func setPermission(_ change: PermissionChange) async throws
    func setLocation(latitude: Double, longitude: Double) async throws
    func clearLocation() async throws
    func setAppearance(_ appearance: Appearance) async throws
}

// MARK: - AI Context

public protocol AIContextProvider: Sendable {
    func getScreenContext() async throws -> ScreenContext
    func getInteractableElements() async throws -> [ElementInfo]
    func findByDescription(_ description: String) async throws -> [ElementInfo]
}

// MARK: - Composed Driver

public protocol PlatformDriver:
    DeviceDriver,
    AppManagement,
    Actions,
    ScreenCapture,
    AccessibilityProvider,
    DeviceConfigurator,
    AIContextProvider,
    Sendable {}

// MARK: - Default Implementations (throw notImplemented)

public extension TouchActions {
    func tap(at _: Point) async throws {
        throw AmooError.notImplemented("tap")
    }

    func doubleTap(at _: Point) async throws {
        throw AmooError.notImplemented("doubleTap")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        throw AmooError.notImplemented("longPress")
    }

    func tapElement(_: ElementSelector) async throws {
        throw AmooError.notImplemented("tapElement")
    }
}

public extension GestureActions {
    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {
        throw AmooError.notImplemented("swipe")
    }

    func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await swipe(direction: direction, distance: distance, duration: duration, element: nil)
    }

    func swipe(
        direction _: Direction,
        distance _: Double,
        duration _: Duration,
        element _: ElementSelector?
    ) async throws {
        throw AmooError.notImplemented("swipe(direction:element:)")
    }

    func scroll(direction _: Direction, distance _: Double) async throws {
        throw AmooError.notImplemented("scroll")
    }

    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {
        throw AmooError.notImplemented("scrollToElement")
    }

    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {
        throw AmooError.notImplemented("pinch")
    }

    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {
        throw AmooError.notImplemented("drag")
    }
}

public extension TextActions {
    func typeText(_: String) async throws {
        throw AmooError.notImplemented("typeText")
    }

    func clearText(characterCount _: Int?) async throws {
        throw AmooError.notImplemented("clearText")
    }

    func setText(_: ElementSelector, text _: String) async throws {
        throw AmooError.notImplemented("setText")
    }
}

public extension NavigationActions {
    func pressBack() async throws {
        throw AmooError.notImplemented("pressBack")
    }

    func pressHome() async throws {
        throw AmooError.notImplemented("pressHome")
    }

    func openURL(_: String) async throws {
        throw AmooError.notImplemented("openURL")
    }
}

public extension DeviceDriver {
    func boot() async throws {
        throw AmooError.notImplemented("boot")
    }

    func shutdown() async throws {
        throw AmooError.notImplemented("shutdown")
    }

    func deviceInfo() async throws -> DeviceInfo {
        throw AmooError.notImplemented("deviceInfo")
    }
}

public extension AppManagement {
    func installApp(path _: String) async throws {
        throw AmooError.notImplemented("installApp")
    }

    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {
        throw AmooError.notImplemented("launchApp")
    }

    func terminateApp(appID _: String) async throws {
        throw AmooError.notImplemented("terminateApp")
    }

    func uninstallApp(appID _: String) async throws {
        throw AmooError.notImplemented("uninstallApp")
    }

    func listApps() async throws -> [AppInfo] {
        throw AmooError.notImplemented("listApps")
    }

    func appState(appID _: String) async throws -> AppState {
        throw AmooError.notImplemented("appState")
    }
}

public extension ScreenCapture {
    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        throw AmooError.notImplemented("takeScreenshot")
    }

    func startRecording() async throws -> RecordingSession {
        throw AmooError.notImplemented("startRecording")
    }

    func stopRecording(sessionID _: String) async throws -> String {
        throw AmooError.notImplemented("stopRecording")
    }
}

public extension AccessibilityProvider {
    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        throw AmooError.notImplemented("findElements")
    }

    func getViewHierarchy() async throws -> ViewNode {
        throw AmooError.notImplemented("getViewHierarchy")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        throw AmooError.notImplemented("elementExists")
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {
        throw AmooError.notImplemented("waitForElement")
    }

    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {
        throw AmooError.notImplemented("waitForElementToDisappear")
    }

    func isKeyboardVisible() async throws -> Bool {
        throw AmooError.notImplemented("isKeyboardVisible")
    }
}

public extension DeviceConfigurator {
    func setPermission(_: PermissionChange) async throws {
        throw AmooError.notImplemented("setPermission")
    }

    func setLocation(latitude _: Double, longitude _: Double) async throws {
        throw AmooError.notImplemented("setLocation")
    }

    func clearLocation() async throws {
        throw AmooError.notImplemented("clearLocation")
    }

    func setAppearance(_: Appearance) async throws {
        throw AmooError.notImplemented("setAppearance")
    }
}

public extension AIContextProvider {
    func getScreenContext() async throws -> ScreenContext {
        throw AmooError.notImplemented("getScreenContext")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        throw AmooError.notImplemented("getInteractableElements")
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        throw AmooError.notImplemented("findByDescription")
    }
}
