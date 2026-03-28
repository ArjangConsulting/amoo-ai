import MobileTestingCore

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
    func scroll(direction: Direction, distance: Double) async throws

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
        throw MobileTestingError.notImplemented("doubleTap")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        throw MobileTestingError.notImplemented("longPress")
    }

    func tapElement(_: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws {
        throw MobileTestingError.notImplemented("tapElement")
    }

    func pressHome() async throws {
        throw MobileTestingError.notImplemented("pressHome")
    }

    func scroll(direction _: Direction, distance _: Double) async throws {
        throw MobileTestingError.notImplemented("scroll")
    }

    func clearText(characterCount _: Int?) async throws {
        throw MobileTestingError.notImplemented("clearText")
    }

    func getViewHierarchy(appID _: String?, candidateBundleIDs _: [String]) async throws -> ViewNode {
        throw MobileTestingError.notImplemented("getViewHierarchy")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil, candidateBundleIDs: [])
    }

    func findElements(_: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws
        -> [ElementInfo] {
        throw MobileTestingError.notImplemented("findElements")
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
        throw MobileTestingError.notImplemented("waitForElement")
    }

    func isKeyboardVisible() async throws -> Bool {
        throw MobileTestingError.notImplemented("isKeyboardVisible")
    }

    func takeScreenshot() async throws -> ScreenshotData {
        throw MobileTestingError.notImplemented("takeScreenshot")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        throw MobileTestingError.notImplemented("getInteractableElements")
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        throw MobileTestingError.notImplemented("findByDescription")
    }
}
