import ObjectiveC.runtime
import XCTest

/// Single point of contact with Apple's XCUITest framework.
/// If Apple changes APIs, only this file changes.
///
/// All methods are `@MainActor` because XCUITest APIs must run on the main thread.
/// The gRPC server actor dispatches calls here; `@MainActor` ensures thread safety.
@MainActor
final class XCUITestBridge: @unchecked Sendable {
    private let app: XCUIApplication
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    /// Bundle ID of the companion's own host app, which must never be picked as a gesture target.
    ///
    /// XCUITest *activates* an application before delivering an interaction to it, so a gesture
    /// routed through `app` foregrounds the companion and lands in the fixture UI instead of the
    /// app under test. Excluding it from resolution is what keeps a tap on the real target.
    private let hostBundleID: String?

    /// The app under test, when the session named one. Deliberately lower priority than whatever
    /// is actually frontmost, so a system sheet — a permission alert, Sign in with Apple — still
    /// receives the gesture instead of having the bound app activated out from under it.
    private var targetBundleID: String?

    init(app: XCUIApplication, targetBundleID: String? = nil, hostBundleID: String? = nil) {
        self.app = app
        self.targetBundleID = targetBundleID.flatMap { $0.isEmpty ? nil : $0 }
        self.hostBundleID = hostBundleID ?? Self.bundleID(of: app)
    }

    /// Rebinds the app under test mid-session. A real flow crosses app boundaries, so the target
    /// cannot be fixed for the lifetime of the companion.
    func setTargetApp(bundleID: String?) {
        targetBundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The bound app under test, if the session named one.
    func boundTargetBundleID() -> String? { targetBundleID }

    /// Bundle ID of whatever is frontmost, so a caller can tell where a gesture would land without
    /// paying for a screenshot to find out.
    func currentAppBundleID() -> String? {
        // Reports the *gesture* target, since that is the question being asked: where would a tap
        // land right now. Reporting the query target instead made this say "springboard" while
        // taps were being delivered to the app under test.
        Self.bundleID(of: gestureTarget())
    }

    private static func bundleID(of application: XCUIApplication) -> String? {
        for name in ["bundleID", "bundleId", "bundleIdentifier"] {
            let selector = NSSelectorFromString(name)
            guard application.responds(to: selector),
                let value = application.perform(selector)?.takeUnretainedValue() as? String,
                value.contains(".")
            else { continue }
            return value
        }
        return nil
    }

    // MARK: - Touch

    func tap(x: Double, y: Double) {
        gestureCoordinate(x: x, y: y).tap()
    }

    func doubleTap(x: Double, y: Double) {
        gestureCoordinate(x: x, y: y).doubleTap()
    }

    func longPress(x: Double, y: Double, durationSeconds: TimeInterval) {
        gestureCoordinate(x: x, y: y).press(forDuration: durationSeconds)
    }

    /// A screen coordinate expressed against the app a gesture should land in.
    ///
    /// Coordinates were previously taken against `app` — the companion's own host app — so every
    /// tap activated the fixture and was delivered there, whatever was actually on screen.
    private func gestureCoordinate(x: Double, y: Double) -> XCUICoordinate {
        gestureTarget().coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
    }

    /// The app a gesture is delivered through.
    ///
    /// Deliberately ordered differently from ``resolvedTargetApp(bundleID:candidateBundleIDs:)``.
    /// Queries want whatever is frontmost, so system UI stays findable. Gestures want the app
    /// under test whenever it is foreground: SpringBoard reports itself as running-foreground too,
    /// and coordinate taps routed through it land on empty chrome and are silently swallowed —
    /// the command reports success and nothing happens. Falling through to the query order only
    /// once the target is no longer foreground is what keeps system sheets reachable.
    private func gestureTarget() -> XCUIApplication {
        // The bound target wins outright, without consulting `state`. Two reasons: an app launched
        // outside this test process is not reliably reported as `.runningForeground`, and
        // SpringBoard *is* — so a state check hands gestures to SpringBoard, whose window swallows
        // coordinate taps and reports success while nothing happens. Routing through the app is
        // also correct when system UI is on top: the tap synthesizes a touch at that screen point,
        // which whatever is frontmost receives. Callers that need to address a different process
        // explicitly can pass a bundle ID or unbind with `set_target_app`.
        if let targetBundleID {
            return XCUIApplication(bundleIdentifier: targetBundleID)
        }
        return resolvedTargetApp(bundleID: nil, candidateBundleIDs: [])
    }

    // MARK: - Gestures

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationSeconds: TimeInterval) {
        let start = gestureCoordinate(x: fromX, y: fromY)
        let end = gestureCoordinate(x: toX, y: toY)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
    }

    /// A true drag: dwell at the origin long enough for the target to enter a drag
    /// state, travel to the destination at a velocity derived from `durationSeconds`,
    /// then settle briefly before releasing so drop targets register the finish.
    ///
    /// The origin dwell is what separates this from ``swipe(fromX:fromY:toX:toY:durationSeconds:)``,
    /// which uses a fixed 0.05s press purely to start the pan.
    func drag(
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationSeconds: TimeInterval,
        holdSeconds: TimeInterval
    ) {
        let start = gestureCoordinate(x: fromX, y: fromY)
        let end = gestureCoordinate(x: toX, y: toY)

        let distance = hypot(toX - fromX, toY - fromY)
        let velocity: XCUIGestureVelocity = durationSeconds > 0
            ? XCUIGestureVelocity(rawValue: distance / durationSeconds)
            : .default

        start.press(
            forDuration: holdSeconds,
            thenDragTo: end,
            withVelocity: velocity,
            thenHoldForDuration: Self.dropSettleSeconds
        )
    }

    /// Brief dwell at the destination before lifting, giving drop targets a chance to
    /// register the drag finishing over them.
    private static let dropSettleSeconds: TimeInterval = 0.2

    func scroll(direction: ScrollDirection, distance: Double) {
        let target = gestureTarget()
        switch direction {
        case .up:
            target.swipeDown(velocity: .init(distance))
        case .down:
            target.swipeUp(velocity: .init(distance))
        case .left:
            target.swipeRight(velocity: .init(distance))
        case .right:
            target.swipeLeft(velocity: .init(distance))
        }
    }

    func swipeInDirection(
        _ direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) {
        let target = gestureTarget()
        if id != nil || label != nil || containsText != nil {
            let allElements = collectedElements(in: target)
            for element in allElements
                where matches(element: element, id: id, label: label, containsText: containsText) {
                guard element.exists else { continue }
                switch direction {
                case .up: element.swipeUp()
                case .down: element.swipeDown()
                case .left: element.swipeLeft()
                case .right: element.swipeRight()
                }
                return
            }
        }
        switch direction {
        case .up: target.swipeUp()
        case .down: target.swipeDown()
        case .left: target.swipeLeft()
        case .right: target.swipeRight()
        }
    }

    // MARK: - Text

    func typeText(_ text: String) {
        guard let textInput = resolvedTextInput() else { return }
        focusForTextEntry(textInput)
        gestureTarget().typeText(text)
    }

    func clearText(characterCount: Int?) {
        guard let textInput = resolvedTextInput() else { return }
        focusForTextEntry(textInput)

        let currentText = (textInput.value as? String) ?? ""
        let deleteCount = characterCount ?? currentText.count
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount)
        gestureTarget().typeText(deleteString)
    }

    // MARK: - Navigation

    func pressBack() {
        gestureTarget().navigationBars.buttons.element(boundBy: 0).tap()
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
        let allElements = collectedElements(in: target)

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
        let allElements = collectedElements(in: target)

        for element in allElements where matches(element: element, id: id, label: label, containsText: containsText) {
            guard element.exists else { continue }
            if element.isHittable {
                element.tap()
                return true
            }

            let frame = element.frame.standardized
            guard !frame.isNull, !frame.isEmpty else { continue }

            let coordinate = target.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            coordinate.tap()
            return true
        }

        return false
    }

    func getViewHierarchy(bundleID: String? = nil, candidateBundleIDs: [String] = []) -> ViewNodeSnapshot {
        let target = resolvedTargetApp(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs)
        let viewport = visibleViewport(for: target)
        let maxDepth = 25
        // Use snapshot() to fetch the entire element tree in a single IPC call.
        // This is dramatically faster than querying individual XCUIElement properties,
        // where each .identifier, .label, .frame etc. is a separate round-trip.
        if let snapshot = try? target.snapshot() {
            return buildHierarchyFromSnapshot(snapshot, depth: 0, maxDepth: maxDepth, viewport: viewport, isRoot: true)
        }
        return buildHierarchy(element: target, depth: 0, maxDepth: maxDepth, viewport: viewport, isRoot: true)
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

    private func buildHierarchyFromSnapshot(
        _ snapshot: XCUIElementSnapshot,
        depth: Int,
        maxDepth: Int,
        viewport: CGRect,
        isRoot: Bool = false
    ) -> ViewNodeSnapshot {
        let children: [ViewNodeSnapshot] = if depth < maxDepth {
            snapshot.children.map {
                buildHierarchyFromSnapshot($0, depth: depth + 1, maxDepth: maxDepth, viewport: viewport)
            }.compactMap { child in
                child.isVisible || !child.children.isEmpty ? child : nil
            }
        } else {
            []
        }

        let visibleFrame = snapshotVisibleFrame(snapshot)
        let isVisible = isRoot || isSnapshotVisible(snapshot, visibleFrame: visibleFrame, viewport: viewport)

        return ViewNodeSnapshot(
            id: stableNodeID(identifier: snapshot.identifier, label: snapshot.label),
            label: snapshot.label,
            type: "\(snapshot.elementType)",
            frame: snapshot.frame,
            isEnabled: snapshot.isEnabled,
            isVisible: isVisible,
            children: children
        )
    }

    private func buildHierarchy(
        element: XCUIElement,
        depth: Int,
        maxDepth: Int,
        viewport: CGRect,
        isRoot: Bool = false
    ) -> ViewNodeSnapshot {
        let children: [ViewNodeSnapshot] = if depth < maxDepth {
            element.children(matching: .any).allElementsBoundByIndex.map {
                buildHierarchy(element: $0, depth: depth + 1, maxDepth: maxDepth, viewport: viewport)
            }.compactMap { child in
                child.isVisible || !child.children.isEmpty ? child : nil
            }
        } else {
            []
        }

        let isVisible = isRoot || isElementVisible(element, viewport: viewport)

        return ViewNodeSnapshot(
            id: stableNodeID(identifier: element.identifier, label: element.label),
            label: element.label,
            type: "\(element.elementType)",
            frame: element.frame,
            isEnabled: element.isEnabled,
            isVisible: isVisible,
            children: children
        )
    }

    private func visibleViewport(for target: XCUIApplication) -> CGRect {
        let targetFrame = target.frame.standardized
        if !targetFrame.isNull, !targetFrame.isEmpty {
            return targetFrame
        }

        return CGRect(origin: .zero, size: XCUIScreen.main.screenshot().image.size).standardized
    }

    private func isElementVisible(_ element: XCUIElement, viewport: CGRect) -> Bool {
        guard element.exists else {
            return false
        }

        let frame = element.frame.standardized
        guard !frame.isNull, !frame.isEmpty else {
            return false
        }

        return frame.intersects(viewport)
    }

    private func isSnapshotVisible(
        _ snapshot: XCUIElementSnapshot,
        visibleFrame: CGRect?,
        viewport: CGRect
    ) -> Bool {
        if let visibleFrame {
            let frame = visibleFrame.standardized
            return !frame.isNull && !frame.isEmpty && frame.intersects(viewport)
        }

        let frame = snapshot.frame.standardized
        return !frame.isNull && !frame.isEmpty && frame.intersects(viewport)
    }

    private func snapshotVisibleFrame(_ snapshot: XCUIElementSnapshot) -> CGRect? {
        guard let object = snapshot as? NSObject,
              let rawFrame = valueForSelector(named: "visibleFrame", on: object)
        else {
            return nil
        }

        if let value = rawFrame as? NSValue {
            return value.cgRectValue
        }

        return nil
    }

    /// Resolves the application a command applies to.
    ///
    /// Order matters. An explicit `bundleID` always wins. Otherwise the frontmost app wins, which
    /// is what makes system UI — permission alerts, Sign in with Apple — reachable without the
    /// caller naming a bundle ID it cannot know. The session's bound target is the fallback for
    /// when the app under test is merely backgrounded, and only then is it activated.
    ///
    /// The companion's own host app is excluded throughout: XCUITest activates an app before
    /// delivering an interaction, so resolving to it foregrounds the fixture and swallows the
    /// gesture. It stays as the last-resort return purely so this can never return nothing.
    private func resolvedTargetApp(bundleID: String?, candidateBundleIDs: [String]) -> XCUIApplication {
        if let bundleID, !bundleID.isEmpty {
            return XCUIApplication(bundleIdentifier: bundleID)
        }

        if let frontmost = frontmostActiveApplication() {
            return frontmost
        }

        if let targetBundleID {
            return XCUIApplication(bundleIdentifier: targetBundleID)
        }

        if let frontmost = candidateBundleIDs
            .lazy
            .filter({ $0 != self.hostBundleID })
            .map({ XCUIApplication(bundleIdentifier: $0) })
            .first(where: { $0.state == .runningForeground }) {
            return frontmost
        }

        if springboard.state == .runningForeground {
            return springboard
        }

        return app
    }

    /// Prefer XCTest's active app list when available so we don't need a host-side
    /// scan across every installed bundle ID just to identify the frontmost app.
    ///
    /// The companion's own host app is filtered out: it is always running (it hosts this test
    /// bundle), so leaving it in would let it win the "frontmost" race and capture every gesture.
    private func frontmostActiveApplication() -> XCUIApplication? {
        if let activeApps = invokeXCUIApplicationClassSelector(named: "activeApplications") as? [XCUIApplication],
           let frontmost = activeApps.first(where: { isSelectableTarget($0) }) {
            return frontmost
        }

        let selectors = ["activeAppsInfo", "activeApplications"]
        for selectorName in selectors {
            guard let rawValue = invokeXCUIApplicationClassSelector(named: selectorName) else { continue }
            for bundleID in extractBundleIDs(from: rawValue) where bundleID != hostBundleID {
                let candidate = XCUIApplication(bundleIdentifier: bundleID)
                if candidate.state == .runningForeground {
                    return candidate
                }
            }
        }

        return nil
    }

    /// Foreground *and* not the companion itself.
    private func isSelectableTarget(_ candidate: XCUIApplication) -> Bool {
        guard candidate.state == .runningForeground else { return false }
        guard let hostBundleID else { return true }
        return Self.bundleID(of: candidate) != hostBundleID
    }

    private func invokeXCUIApplicationClassSelector(named name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard let applicationClass = NSClassFromString("XCUIApplication"),
              let method = class_getClassMethod(applicationClass, selector)
        else {
            return nil
        }

        typealias Function = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(applicationClass, selector)?.takeUnretainedValue()
    }

    private func extractBundleIDs(from rawValue: Any) -> [String] {
        let values: [Any] = if let array = rawValue as? [Any] {
            array
        } else if let array = rawValue as? NSArray {
            array.compactMap(\.self)
        } else {
            [rawValue]
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
                    valueForSelector(named: "bundleID", on: object) as Any,
                    valueForSelector(named: "bundleId", on: object) as Any,
                    valueForSelector(named: "bundleIdentifier", on: object) as Any
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

    private func resolvedTextInput() -> XCUIElement? {
        let primaryCandidates = textInputCandidates(in: app)
        for candidate in primaryCandidates where candidate.exists && candidate.isHittable {
            return candidate
        }

        for candidate in primaryCandidates where candidate.exists {
            return candidate
        }

        let target = resolvedTargetApp(bundleID: nil, candidateBundleIDs: [])
        let candidates = textInputCandidates(in: target)

        for candidate in candidates where candidate.exists && candidate.isHittable {
            return candidate
        }

        for candidate in candidates where candidate.exists {
            return candidate
        }

        return nil
    }

    private func textInputCandidates(in target: XCUIApplication) -> [XCUIElement] {
        target.descendants(matching: .textField).allElementsBoundByIndex +
            target.descendants(matching: .textView).allElementsBoundByIndex +
            target.descendants(matching: .secureTextField).allElementsBoundByIndex
    }

    private func focus(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
            return
        }

        let frame = element.frame.standardized
        guard !frame.isNull, !frame.isEmpty else { return }

        let target = resolvedTargetApp(bundleID: nil, candidateBundleIDs: [])
        let coordinate = target.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        coordinate.tap()
    }

    private func focusForTextEntry(_ element: XCUIElement) {
        guard element.exists else { return }

        if element.isHittable {
            let coordinate = element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            coordinate.tap()
            return
        }

        let frame = element.frame.standardized
        guard !frame.isNull, !frame.isEmpty else {
            focus(element)
            return
        }

        let target = app
        let coordinate = target.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.maxX - 8, dy: frame.midY))
        coordinate.tap()
    }

    private func collectedElements(in target: XCUIApplication) -> [XCUIElement] {
        let queries: [XCUIElementQuery] = [
            target.buttons,
            target.staticTexts,
            target.textFields,
            target.textViews,
            target.secureTextFields,
            target.cells,
            target.links,
            target.images,
            target.switches,
            target.sliders
        ]

        var elements: [XCUIElement] = []
        var seen = Set<String>()

        for query in queries {
            for element in query.allElementsBoundByAccessibilityElement {
                let key = [
                    String(element.elementType.rawValue),
                    element.identifier,
                    element.label,
                    NSCoder.string(for: element.frame.standardized)
                ].joined(separator: "|")
                if seen.insert(key).inserted {
                    elements.append(element)
                }
            }
        }

        return elements
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
