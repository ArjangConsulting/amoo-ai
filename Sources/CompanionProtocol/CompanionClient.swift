import AmooCore

public protocol CompanionClient: Sendable {
    // Session
    func startSession() async throws
    func getCapabilities() async throws -> [CapabilityDescriptor]
    func endSession() async throws

    // Touch
    func tap(at point: Point) async throws
    func doubleTap(at point: Point) async throws
    func longPress(at point: Point, duration: Duration) async throws
    func tapElement(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws

    // Gestures
    func swipe(from: Point, to: Point, duration: Duration) async throws
    func swipeInDirection(
        _ direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws
    func scroll(direction: Direction, distance: Double) async throws
    func drag(from: Point, to: Point, duration: Duration, holdDuration: Duration) async throws

    // Text
    func typeText(_ text: String) async throws
    func clearText(characterCount: Int?) async throws
    func setText(_ selector: ElementSelector, text: String, appID: String?, candidateBundleIDs: [String]) async throws

    // Navigation
    func pressBack() async throws
    func pressHome() async throws

    /// Accessibility
    func findElements(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws
        -> [ElementInfo]
    func getViewHierarchy(appID: String?, candidateBundleIDs: [String]) async throws -> ViewNode
    func waitForElement(_ selector: ElementSelector, timeout: Duration, appID: String?, candidateBundleIDs: [String])
        async throws
    func isKeyboardVisible() async throws -> Bool

    /// Target app
    ///
    /// `currentApp` reports where a gesture would land right now; `setTargetApp` rebinds the app
    /// under test for the rest of the session (empty/nil falls back to whatever is frontmost).
    func currentApp() async throws -> CurrentAppInfo
    func setTargetApp(bundleID: String?) async throws
    /// `appID`'s own run state, resolved directly via the companion's public
    /// `XCUIApplication(bundleIdentifier:).state` — not by asking who is frontmost. See
    /// `GetAppStateResponse` in actions.proto for why that distinction is load-bearing: the
    /// frontmost-guessing path this sidesteps was found to report stale answers for many
    /// seconds after a launch or app switch.
    func appState(appID: String) async throws -> String
    /// Point/pixel geometry of the screen, for converting positions read off a screenshot.
    func screenInfo() async throws -> ScreenGeometry

    /// Capture
    func takeScreenshot() async throws -> ScreenshotData

    // AI
    func getScreenContext() async throws -> ScreenContext
    func getInteractableElements() async throws -> [ElementInfo]
    func findByDescription(_ description: String) async throws -> [ElementInfo]
}

/// Default implementations for methods that not every companion may support yet
public extension CompanionClient {
    func tapElement(_ selector: ElementSelector) async throws {
        try await tapElement(selector, appID: nil, candidateBundleIDs: [])
    }

    func doubleTap(at _: Point) async throws {
        throw AmooError.notImplemented("doubleTap")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        throw AmooError.notImplemented("longPress")
    }

    func tapElement(_: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws {
        throw AmooError.notImplemented("tapElement")
    }

    func pressHome() async throws {
        throw AmooError.notImplemented("pressHome")
    }

    func swipeInDirection(
        _: Direction,
        distance _: Double,
        duration _: Duration,
        element _: ElementSelector?
    ) async throws {
        throw AmooError.notImplemented("swipeInDirection")
    }

    func scroll(direction _: Direction, distance _: Double) async throws {
        throw AmooError.notImplemented("scroll")
    }

    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {
        throw AmooError.notImplemented("drag")
    }

    func clearText(characterCount _: Int?) async throws {
        throw AmooError.notImplemented("clearText")
    }

    func setText(_ selector: ElementSelector, text: String) async throws {
        try await setText(selector, text: text, appID: nil, candidateBundleIDs: [])
    }

    func setText(
        _: ElementSelector,
        text _: String,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws {
        throw AmooError.notImplemented("setText")
    }

    func getViewHierarchy(appID _: String?, candidateBundleIDs _: [String]) async throws -> ViewNode {
        throw AmooError.notImplemented("getViewHierarchy")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil, candidateBundleIDs: [])
    }

    func findElements(_: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws
        -> [ElementInfo] {
        throw AmooError.notImplemented("findElements")
    }

    func waitForElement(_ selector: ElementSelector, timeout: Duration) async throws {
        try await waitForElement(selector, timeout: timeout, appID: nil, candidateBundleIDs: [])
    }

    func waitForElement(
        _: ElementSelector,
        timeout _: Duration,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws {
        throw AmooError.notImplemented("waitForElement")
    }

    func isKeyboardVisible() async throws -> Bool {
        throw AmooError.notImplemented("isKeyboardVisible")
    }

    func currentApp() async throws -> CurrentAppInfo {
        throw AmooError.notImplemented("currentApp")
    }

    func setTargetApp(bundleID _: String?) async throws {
        throw AmooError.notImplemented("setTargetApp")
    }

    func appState(appID _: String) async throws -> String {
        throw AmooError.notImplemented("appState")
    }

    func screenInfo() async throws -> ScreenGeometry {
        throw AmooError.notImplemented("screenInfo")
    }

    func takeScreenshot() async throws -> ScreenshotData {
        throw AmooError.notImplemented("takeScreenshot")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        throw AmooError.notImplemented("getInteractableElements")
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        throw AmooError.notImplemented("findByDescription")
    }
}

/// Where a gesture would land, and what the session bound as the app under test.
public struct CurrentAppInfo: Sendable, Equatable {
    /// Frontmost application, empty when it could not be determined.
    public let bundleID: String
    /// Bound app under test, empty when unbound.
    public let targetBundleID: String

    public init(bundleID: String, targetBundleID: String) {
        self.bundleID = bundleID
        self.targetBundleID = targetBundleID
    }
}

/// The two coordinate spaces a caller has to reconcile: gestures take points, screenshots come
/// back in pixels, and on a Retina device they differ by `scale`.
public struct ScreenGeometry: Sendable, Equatable {
    public let widthPoints: Double
    public let heightPoints: Double
    public let widthPixels: Double
    public let heightPixels: Double
    public let scale: Double

    public init(
        widthPoints: Double,
        heightPoints: Double,
        widthPixels: Double,
        heightPixels: Double,
        scale: Double
    ) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.scale = scale
    }
}
