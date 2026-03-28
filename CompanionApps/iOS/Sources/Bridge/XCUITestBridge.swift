import XCTest
import ObjectiveC.runtime

/// Single point of contact with Apple's XCUITest framework.
/// If Apple changes APIs, only this file changes.
///
/// All methods are `@MainActor` because XCUITest APIs must run on the main thread.
/// The gRPC server actor dispatches calls here; `@MainActor` ensures thread safety.
@MainActor
final class XCUITestBridge: @unchecked Sendable {
    private let app: XCUIApplication
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Touch

    func tap(x: Double, y: Double) {
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
        coordinate.tap()
    }

    func doubleTap(x: Double, y: Double) {
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
        coordinate.doubleTap()
    }

    func longPress(x: Double, y: Double, durationSeconds: TimeInterval) {
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
        coordinate.press(forDuration: durationSeconds)
    }

    // MARK: - Gestures

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationSeconds: TimeInterval) {
        let start = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: fromX, dy: fromY))
        let end = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: toX, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
    }

    func scroll(direction: ScrollDirection, distance: Double) {
        switch direction {
        case .up:
            app.swipeUp(velocity: .init(distance))
        case .down:
            app.swipeDown(velocity: .init(distance))
        case .left:
            app.swipeLeft(velocity: .init(distance))
        case .right:
            app.swipeRight(velocity: .init(distance))
        }
    }

    // MARK: - Text

    func typeText(_ text: String) {
        let focusedElement = app.textFields.element(boundBy: 0)
        if focusedElement.exists {
            focusedElement.typeText(text)
        } else {
            let textView = app.textViews.element(boundBy: 0)
            if textView.exists {
                textView.typeText(text)
            }
        }
    }

    func clearText(characterCount: Int?) {
        let focusedElement = app.textFields.element(boundBy: 0).exists
            ? app.textFields.element(boundBy: 0)
            : app.textViews.element(boundBy: 0)

        guard focusedElement.exists else { return }

        let currentText = (focusedElement.value as? String) ?? ""
        let deleteCount = characterCount ?? currentText.count
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount)
        focusedElement.typeText(deleteString)
    }

    // MARK: - Navigation

    func pressBack() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    func pressHome() {
        XCUIDevice.shared.press(.home)
    }

    // MARK: - Accessibility Queries

    func findElements(
        id: String?,
        label: String?,
        containsText: String?,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = []
    ) -> [ElementSnapshot] {
        var results: [ElementSnapshot] = []

        let target = resolvedTargetApp(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
        let allElements = target.descendants(matching: .any).allElementsBoundByAccessibilityElement

        for element in allElements {
            if matches(element: element, id: id, label: label, containsText: containsText) {
                results.append(ElementSnapshot(
                    id: element.identifier,
                    label: element.label,
                    value: (element.value as? String) ?? "",
                    type: "\(element.elementType)",
                    frame: element.frame,
                    isEnabled: element.isEnabled,
                    isVisible: element.exists && element.isHittable
                ))
            }
        }

        return results
    }

    func tapElement(
        id: String?,
        label: String?,
        containsText: String?,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = []
    ) -> Bool {
        let target = resolvedTargetApp(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
        let allElements = target.descendants(matching: .any).allElementsBoundByAccessibilityElement

        for element in allElements where matches(element: element, id: id, label: label, containsText: containsText) {
            guard element.exists, element.isHittable else { continue }
            element.tap()
            return true
        }

        return false
    }

    func getViewHierarchy(bundleID: String? = nil, candidateBundleIDs: [String] = []) -> ViewNodeSnapshot {
        let target = resolvedTargetApp(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
        // Use snapshot() to fetch the entire element tree in a single IPC call.
        // This is dramatically faster than querying individual XCUIElement properties,
        // where each .identifier, .label, .frame etc. is a separate round-trip.
        if let snapshot = try? target.snapshot() {
            return buildHierarchyFromSnapshot(snapshot, depth: 0, maxDepth: 10)
        }
        return buildHierarchy(element: target, depth: 0, maxDepth: 10)
    }

    func isKeyboardVisible() -> Bool {
        resolvedTargetApp(bundleID: nil, candidateBundleIDs: []).keyboards.count > 0
    }

    // MARK: - Screenshot

    func takeScreenshot() -> Data {
        let screenshot = XCUIScreen.main.screenshot()
        return screenshot.pngRepresentation
    }

    // MARK: - Private

    private func buildHierarchyFromSnapshot(_ snapshot: XCUIElementSnapshot, depth: Int, maxDepth: Int) -> ViewNodeSnapshot {
        let children: [ViewNodeSnapshot]
        if depth < maxDepth {
            children = snapshot.children.map {
                buildHierarchyFromSnapshot($0, depth: depth + 1, maxDepth: maxDepth)
            }
        } else {
            children = []
        }

        return ViewNodeSnapshot(
            id: stableNodeID(identifier: snapshot.identifier, label: snapshot.label),
            label: snapshot.label,
            type: "\(snapshot.elementType)",
            frame: snapshot.frame,
            isEnabled: snapshot.isEnabled,
            isVisible: true,
            children: children
        )
    }

    private func buildHierarchy(element: XCUIElement, depth: Int, maxDepth: Int) -> ViewNodeSnapshot {
        let children: [ViewNodeSnapshot]
        if depth < maxDepth {
            children = element.children(matching: .any).allElementsBoundByIndex.map {
                buildHierarchy(element: $0, depth: depth + 1, maxDepth: maxDepth)
            }
        } else {
            children = []
        }

        return ViewNodeSnapshot(
            id: stableNodeID(identifier: element.identifier, label: element.label),
            label: element.label,
            type: "\(element.elementType)",
            frame: element.frame,
            isEnabled: element.isEnabled,
            isVisible: element.exists,
            children: children
        )
    }

    private func resolvedTargetApp(bundleID: String?, candidateBundleIDs: [String]) -> XCUIApplication {
        if let bundleID, !bundleID.isEmpty {
            return XCUIApplication(bundleIdentifier: bundleID)
        }

        if let frontmost = frontmostActiveApplication() {
            return frontmost
        }

        if let frontmost = candidateBundleIDs
            .lazy
            .map({ XCUIApplication(bundleIdentifier: $0) })
            .first(where: { $0.state == .runningForeground }) {
            return frontmost
        }

        if springboard.state == .runningForeground {
            return springboard
        }

        if app.state == .runningForeground {
            return app
        }

        return app
    }

    // Prefer XCTest's active app list when available so we don't need a host-side
    // scan across every installed bundle ID just to identify the frontmost app.
    private func frontmostActiveApplication() -> XCUIApplication? {
        if let activeApps = invokeXCUIApplicationClassSelector(named: "activeApplications") as? [XCUIApplication],
           let frontmost = activeApps.first(where: { $0.state == .runningForeground }) {
            return frontmost
        }

        let selectors = ["activeAppsInfo", "activeApplications"]
        for selectorName in selectors {
            guard let rawValue = invokeXCUIApplicationClassSelector(named: selectorName) else { continue }
            for bundleID in extractBundleIDs(from: rawValue) {
                let candidate = XCUIApplication(bundleIdentifier: bundleID)
                if candidate.state == .runningForeground {
                    return candidate
                }
            }
        }

        return nil
    }

    private func invokeXCUIApplicationClassSelector(named name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard let applicationClass = NSClassFromString("XCUIApplication"),
              let method = class_getClassMethod(applicationClass, selector) else {
            return nil
        }

        typealias Function = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(applicationClass, selector)?.takeUnretainedValue()
    }

    private func extractBundleIDs(from rawValue: Any) -> [String] {
        let values: [Any]
        if let array = rawValue as? [Any] {
            values = array
        } else if let array = rawValue as? NSArray {
            values = array.compactMap { $0 }
        } else {
            values = [rawValue]
        }

        return values.compactMap { value in
            if let dict = value as? [String: Any] {
                return bundleID(from: Array(dict.values))
            }

            if let dict = value as? NSDictionary {
                return bundleID(from: dict.allValues)
            }

            if let object = value as? NSObject {
                return bundleID(from: [
                    valueForSelector(named: "bundleID", on: object),
                    valueForSelector(named: "bundleId", on: object),
                    valueForSelector(named: "bundleIdentifier", on: object),
                ])
            }

            return nil
        }
    }

    private func bundleID(from values: [Any]) -> String? {
        for value in values {
            if let bundleID = value as? String, bundleID.contains(".") {
                return bundleID
            }
        }

        return nil
    }

    private func valueForSelector(named name: String, on object: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else {
            return nil
        }

        return object.perform(selector)?.takeUnretainedValue()
    }

    private func matches(
        element: XCUIElement,
        id: String?,
        label: String?,
        containsText: String?
    ) -> Bool {
        var isMatch = true

        if let id, !id.isEmpty {
            isMatch = isMatch && element.identifier == id
        }
        if let label, !label.isEmpty {
            isMatch = isMatch && element.label == label
        }
        if let containsText, !containsText.isEmpty {
            isMatch = isMatch && element.label.contains(containsText)
        }

        return isMatch
    }

    private func stableNodeID(identifier: String, label: String?) -> String {
        if !identifier.isEmpty {
            return identifier
        }

        if let label, !label.isEmpty {
            return label
        }

        return "root"
    }
}
