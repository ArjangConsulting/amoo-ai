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
