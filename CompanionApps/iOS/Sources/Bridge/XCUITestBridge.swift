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

    /// The element most recently targeted by `tapElement`. Text RPCs arrive separately and XCTest
    /// otherwise resolves the first text field on screen, which can silently redirect input away
    /// from the field the caller just focused.
    private var lastTappedElementID: String?
    private var lastTappedElementLabel: String?

    /// The app under test, when the session named one. Deliberately lower priority than whatever
    /// is actually frontmost, so a system sheet — a permission alert, Sign in with Apple — still
    /// receives the gesture instead of having the bound app activated out from under it.
    private var targetBundleID: String?

    /// The most recent accessibility snapshot, reused for queries that arrive before anything can
    /// have changed it.
    ///
    /// `target.snapshot()` is the entire cost of a query RPC — measured on a booted iPhone 17 Pro,
    /// `find_elements` is 188ms and `describe_screen` 429ms, while a no-op RPC (`current_app`) is
    /// 3ms. So the gRPC hop is free and the tree walk is everything. Agents habitually query
    /// several times between actions ("did it appear?", "what's on screen?", then a selector
    /// lookup), and each of those was re-walking an identical tree.
    ///
    /// Correctness rests on two things:
    ///
    /// - **Every action invalidates.** `invalidateSnapshotCache()` is called by each gesture, text
    ///   entry and lifecycle RPC. If a new mutating RPC is added and forgets to call it, queries
    ///   after that action return pre-action state — so the call belongs next to the gesture, not
    ///   in a wrapper someone can route around.
    /// - **A short TTL bounds what invalidation cannot catch.** An app changes on its own: a
    ///   network response lands, an animation settles, a timer fires. No invalidation hook sees
    ///   any of that, so an entry expires on time as well as on action.
    ///
    /// The TTL is also what keeps polling assertions correct. `assert_visible`, `assert_enabled`
    /// and `assert_screen_changed` loop *host-side*, so the companion cannot tell a poll from a
    /// one-shot query and has nothing to bypass on. With expiry, a poll observes a change at worst
    /// one TTL late — a bounded delay inside a multi-second timeout. Without expiry the same loop
    /// would re-read identical bytes until its deadline and report a timeout for a change that did
    /// happen, which is why this cache must never be given an unbounded lifetime.
    private struct CachedSnapshot {
        let bundleID: String?
        let snapshot: XCUIElementSnapshot
        let takenAt: Date
    }

    private var cachedSnapshot: CachedSnapshot?

    /// XCTest waits for the target process to quiesce before and after every synthesized event.
    /// That is useful for standalone XCTest methods, but redundant here: the companion returns
    /// after injection and the host's assertion tools perform their own bounded polling. On an
    /// otherwise idle simulator those two implicit waits account for most of a ~430ms no-op tap.
    ///
    /// XCTest exposes no public switch, but its process flags are Objective-C runtime methods.
    /// Override the installed Xcode's pre/post-event flags, falling back to its older wait-method
    /// signatures. The lookup is guarded, so a future Xcode that removes or renames these methods
    /// simply retains the slower public behavior. Set `AMOO_IOS_WAIT_FOR_QUIESCENCE=1` to retain
    /// XCTest's waits while diagnosing an app that depends on them.
    private static let fastInteractionEnabled: Bool = {
        guard ProcessInfo.processInfo.environment["AMOO_IOS_WAIT_FOR_QUIESCENCE"] != "1",
              let processClass = NSClassFromString("XCUIApplicationProcess")
        else { return false }

        var replacedMethod = false

        // Current XCTest asks these process flags immediately around event synthesis. Prefer
        // overriding them because snapshots and lifecycle operations retain their normal waits.
        let skipWait: @convention(block) (AnyObject) -> Bool = { _ in true }
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            let selector = NSSelectorFromString(name)
            if let method = class_getInstanceMethod(processClass, selector) {
                method_setImplementation(method, imp_implementationWithBlock(skipWait))
                replacedMethod = true
            }
        }

        if replacedMethod {
            return true
        }

        // Older XCTest versions have no skip flags. Fall back to replacing their wait entrypoint.
        let currentSelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let method = class_getInstanceMethod(processClass, currentSelector) {
            let noWait: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(noWait))
            replacedMethod = true
        }

        let legacySelector = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
        if let method = class_getInstanceMethod(processClass, legacySelector) {
            let noWait: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(noWait))
            replacedMethod = true
        }

        return replacedMethod
    }()

    /// Deliberately short. It exists to collapse the burst of queries an agent issues about one
    /// screen state, not to hold a tree across anything a person would perceive as a wait.
    private static let snapshotCacheTTL: TimeInterval = 0.15

    init(app: XCUIApplication, targetBundleID: String? = nil, hostBundleID: String? = nil) {
        _ = Self.fastInteractionEnabled
        self.app = app
        self.targetBundleID = targetBundleID.flatMap { $0.isEmpty ? nil : $0 }
        self.hostBundleID = hostBundleID ?? Self.bundleID(of: app)
    }

    /// A snapshot of `target`, reusing the cached one when it is for the same app and still within
    /// the TTL. Use for one-shot queries.
    private func snapshot(of target: XCUIApplication) -> XCUIElementSnapshot? {
        let bundleID = Self.bundleID(of: target)
        if let cached = cachedSnapshot,
           cached.bundleID == bundleID,
           Date().timeIntervalSince(cached.takenAt) < Self.snapshotCacheTTL {
            return cached.snapshot
        }
        return freshSnapshot(of: target)
    }

    /// A snapshot taken now, ignoring and replacing the cache.
    ///
    /// Every polling caller must use this. `assert_visible`, `assert_enabled` and
    /// `assert_screen_changed` loop until the screen changes; served a cached tree they would
    /// re-read the same bytes until the deadline and report a timeout for a change that did in
    /// fact happen. A stale read there converts a passing assertion into a guaranteed failure.
    private func freshSnapshot(of target: XCUIApplication) -> XCUIElementSnapshot? {
        guard let snapshot = try? target.snapshot() else { return nil }
        cachedSnapshot = CachedSnapshot(
            bundleID: Self.bundleID(of: target),
            snapshot: snapshot,
            takenAt: Date()
        )
        return snapshot
    }

    /// Drops the cached tree. Called by every RPC that can change what is on screen.
    private func invalidateSnapshotCache() {
        cachedSnapshot = nil
    }

    /// Rebinds the app under test mid-session. A real flow crosses app boundaries, so the target
    /// cannot be fixed for the lifetime of the companion.
    func setTargetApp(bundleID: String?) {
        defer { invalidateSnapshotCache() }
        targetBundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The bound app under test, if the session named one.
    func boundTargetBundleID() -> String? {
        targetBundleID
    }

    /// Bundle ID of whatever is frontmost, so a caller can tell where a gesture would land without
    /// paying for a screenshot to find out.
    func currentAppBundleID() -> String? {
        // Do not use `gestureTarget()` here: it deliberately returns the bound app even while
        // another app or system sheet is frontmost. Queries resolve the actual foreground process
        // first, which is the state this API promises to report.
        Self.bundleID(of: resolvedTargetApp(bundleID: nil, candidateBundleIDs: []))
    }

    /// `appID`'s own run state, via `XCUIApplication(bundleIdentifier:).state` directly —
    /// bypasses `resolvedTargetApp`/`currentAppBundleID`'s frontmost-guessing entirely, since the
    /// caller already knows exactly which bundle ID it cares about. A cheap property read: safe
    /// to poll, unlike `.snapshot()` on a backgrounded app (see GetAppStateResponse in
    /// actions.proto for why that distinction matters).
    func appState(appID: String) -> String {
        switch XCUIApplication(bundleIdentifier: appID).state {
        case .runningForeground: "running"
        case .runningBackground, .runningBackgroundSuspended: "suspended"
        case .notRunning: "notRunning"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    static let springboardBundleID = "com.apple.springboard"

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

    func tap(x: Double, y: Double) async {
        defer { invalidateSnapshotCache() }
        clearLastTappedElement()
        await tapWithoutCacheInvalidation(x: x, y: y)
    }

    func doubleTap(x: Double, y: Double) {
        defer { invalidateSnapshotCache() }
        gestureCoordinate(x: x, y: y).doubleTap()
    }

    func longPress(x: Double, y: Double, durationSeconds: TimeInterval) {
        defer { invalidateSnapshotCache() }
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

    /// Uses XCTest's runner-daemon event API when present. Unlike `XCUICoordinate.tap()`, this
    /// returns when synthesis completes without adding an implicit post-event confirmation wait.
    private func tapWithoutCacheInvalidation(x: Double, y: Double) async {
        let target = gestureTarget()
        guard FastTapSynthesizer.isAvailable else {
            gestureCoordinate(x: x, y: y).tap()
            return
        }
        do {
            try await FastTapSynthesizer.tap(
                at: CGPoint(x: x, y: y),
                orientation: interfaceOrientation(of: target)
            )
        } catch {
            // Runtime lookup keeps future XCTest changes from breaking all taps. A synthesis error
            // happens before confirmation, so retrying through the public path is safe here.
            print("Fast tap unavailable; falling back to XCUICoordinate.tap(): \(error)")
            gestureCoordinate(x: x, y: y).tap()
        }
    }

    private func interfaceOrientation(of application: XCUIApplication) -> UIInterfaceOrientation {
        let selector = NSSelectorFromString("interfaceOrientation")
        guard application.responds(to: selector) else { return .portrait }
        let implementation = application.method(for: selector)
        typealias Method = @convention(c) (AnyObject, Selector) -> Int
        let rawValue = unsafeBitCast(implementation, to: Method.self)(application, selector)
        return UIInterfaceOrientation(rawValue: rawValue) ?? .portrait
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
        defer { invalidateSnapshotCache() }
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
        defer { invalidateSnapshotCache() }
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
        defer { invalidateSnapshotCache() }
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

    /// Returns `false` when a selector was supplied but nothing matched, so the caller can report
    /// failure instead of silently swiping the whole target.
    ///
    /// Previously, when `id`/`label`/`containsText` matched no element — including the case where
    /// two rows in a list share the same accessibility label and the intended one isn't the first
    /// hit in tree-walk order — this fell through to a generic `target.swipeLeft()`/`swipeUp()`/
    /// etc. on the *whole* gesture target. XCUITest's directional swipe helpers start from wherever
    /// they choose within that target (typically its centre), which in a scrollable list can land on
    /// an entirely different row than the one named. The action still reported success, so a caller
    /// asking to swipe a specific labelled row could silently act on an unrelated one with no
    /// indication anything went wrong. Callers that want a screen-wide swipe should omit the
    /// selector entirely rather than pass one that might not resolve.
    @discardableResult
    func swipeInDirection(
        _ direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) -> Bool {
        defer { invalidateSnapshotCache() }
        let target = gestureTarget()
        let hasSelector = id != nil || label != nil || containsText != nil
        if hasSelector {
            // Swipes from the matched element's centre, using the same single-snapshot lookup as
            // `findElements` rather than enumerating live queries per element.
            for candidate in matchableElements(in: target, labeledOnly: true)
                where matches(candidate: candidate, id: id, label: label, containsText: containsText) {
                let frame = candidate.frame.standardized
                guard !frame.isNull, !frame.isEmpty else { continue }
                swipeFromCentre(of: frame, direction: direction)
                return true
            }
            return false
        }
        switch direction {
        case .up: target.swipeUp()
        case .down: target.swipeDown()
        case .left: target.swipeLeft()
        case .right: target.swipeRight()
        }
        return true
    }

    // MARK: - Text

    func typeText(_ text: String) {
        defer { invalidateSnapshotCache() }
        guard let textInput = resolvedTextInput() else { return }
        focusForTextEntry(textInput)
        gestureTarget().typeText(text)
    }

    func clearText(characterCount: Int?) {
        defer { invalidateSnapshotCache() }
        guard let textInput = resolvedTextInput() else { return }
        focusForTextEntry(textInput)

        let currentText = (textInput.value as? String) ?? ""
        let deleteCount = characterCount ?? currentText.count
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount)
        gestureTarget().typeText(deleteString)
    }

    func setText(
        id: String?,
        label: String?,
        containsText: String?,
        text: String,
        bundleID: String?,
        candidateBundleIDs: [String]
    ) async -> Bool {
        defer { invalidateSnapshotCache() }
        guard await tapElement(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs
        ) else { return false }
        // `typeText`/`clearText` no-op when nothing resolves as a text input. Without this check
        // a tap that landed on a static label would still report the field as filled.
        guard let textInput = resolvedTextInput() else { return false }
        let before = (textInput.value as? String) ?? ""
        clearText(characterCount: nil)
        typeText(text)
        let after = (textInput.value as? String) ?? ""
        // A secure field reports a mask rather than what was typed, so an exact match is not
        // always available — but the content still has to have moved off what was there before.
        return after == text || (!text.isEmpty && !after.isEmpty && after != before)
    }

    // MARK: - Navigation

    func pressBack() {
        defer { invalidateSnapshotCache() }
        gestureTarget().navigationBars.buttons.element(boundBy: 0).tap()
    }

    func pressHome() {
        defer { invalidateSnapshotCache() }
        XCUIDevice.shared.press(.home)
    }

    // MARK: - Accessibility Queries

    func findElements(
        id: String?,
        label: String?,
        containsText: String?,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = [],
        labeledOnly: Bool = false
    ) -> [ElementSnapshot] {
        // A selector already excludes unlabeled elements — none of them can match an id, a label,
        // or a substring of one — so collecting them is pure work for a result that drops them.
        let namedOnly = labeledOnly || id != nil || label != nil || containsText != nil
        for app in searchOrder(bundleID: bundleID, candidateBundleIDs: candidateBundleIDs) {
            let found = matchableElements(in: app, labeledOnly: namedOnly)
                .filter { matches(candidate: $0, id: id, label: label, containsText: containsText) }
            if !found.isEmpty {
                return found
            }
        }
        return []
    }

    /// The processes a lookup should try, in order.
    ///
    /// An explicit bundle ID is taken at its word. Otherwise the resolved app is tried first and
    /// system UI second, because a permission alert or the Sign in with Apple sheet is drawn by a
    /// *different* process: it sits above the app on screen but is absent from the app's
    /// accessibility tree, so an app-scoped lookup correctly finds nothing for a control the user
    /// is looking straight at. Falling back only when the first pass finds nothing keeps the app's
    /// own matches preferred, and costs one extra snapshot exactly when the answer was going to be
    /// "not found" anyway.
    private func searchOrder(bundleID: String?, candidateBundleIDs: [String]) -> [XCUIApplication] {
        if let bundleID, !bundleID.isEmpty {
            return [XCUIApplication(bundleIdentifier: bundleID)]
        }

        let resolved = resolvedTargetApp(bundleID: nil, candidateBundleIDs: candidateBundleIDs)
        guard Self.bundleID(of: resolved) != Self.springboardBundleID else { return [resolved] }
        return [resolved, springboard]
    }

    func tapElement(
        id: String?,
        label: String?,
        containsText: String?,
        bundleID: String? = nil,
        candidateBundleIDs: [String] = []
    ) async -> Bool {
        defer { invalidateSnapshotCache() }
        // Shares `findElements`' search order, so a control in a system sheet is tappable by
        // label without the caller naming the process it happens to live in. The tap itself is by
        // coordinate, which is process-agnostic — only the lookup needed the scope.
        // Labeled only: a tap needs something the caller named, and an element with no identifier
        // or label is one only `tap` at a coordinate can reach.
        for candidate in findElements(
            id: id,
            label: label,
            containsText: containsText,
            bundleID: bundleID,
            candidateBundleIDs: candidateBundleIDs,
            labeledOnly: true
        ) {
            let frame = candidate.frame.standardized
            guard !frame.isNull, !frame.isEmpty else { continue }
            lastTappedElementID = candidate.id.isEmpty ? nil : candidate.id
            lastTappedElementLabel = candidate.label.isEmpty ? nil : candidate.label
            await tapWithoutCacheInvalidation(x: frame.midX, y: frame.midY)
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
        if let snapshot = snapshot(of: target) {
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

    /// Both coordinate spaces in play, and the factor between them.
    ///
    /// Gestures take points; screenshots come back in pixels. On a 3x device those differ by a
    /// factor of three, so a coordinate read straight off a screenshot lands far off-screen —
    /// and silently, since a tap outside any control still reports success.
    func screenInfo() -> (points: CGSize, pixels: CGSize, scale: Double) {
        let image = XCUIScreen.main.screenshot().image
        let points = image.size
        let scale = Double(image.scale)
        let pixels = CGSize(width: points.width * scale, height: points.height * scale)
        return (points, pixels, scale)
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
            hitPoint: interactionPoint(
                frame: snapshot.frame,
                visibleFrame: visibleFrame,
                viewport: viewport
            ),
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
            hitPoint: interactionPoint(frame: element.frame, visibleFrame: nil, viewport: viewport),
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

    /// Returns a point inside the on-screen portion of an element. A frame's geometric centre
    /// can be clipped outside a scroll view or covered by screen bounds, making it a poor fallback
    /// for elements that cannot be addressed by an accessibility selector.
    private func interactionPoint(frame: CGRect, visibleFrame: CGRect?, viewport: CGRect) -> CGPoint {
        let preferred = (visibleFrame ?? frame).standardized.intersection(viewport.standardized)
        if !preferred.isNull, !preferred.isEmpty {
            return CGPoint(x: preferred.midX, y: preferred.midY)
        }
        return CGPoint(x: frame.midX, y: frame.midY)
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
        candidate: ElementSnapshot,
        id: String?,
        label: String?,
        containsText: String?
    ) -> Bool {
        var isMatch = true

        if let id, !id.isEmpty {
            isMatch = isMatch && candidate.id == id
        }
        if let label, !label.isEmpty {
            isMatch = isMatch && candidate.label == label
        }
        if let containsText, !containsText.isEmpty {
            isMatch = isMatch && candidate.label.contains(containsText)
        }

        return isMatch
    }

    /// Every element a selector could match, read from one tree snapshot.
    ///
    /// This used to enumerate ten live `XCUIElementQuery`s and then read `.identifier`, `.label`,
    /// `.frame`, `.isEnabled` and `.isHittable` off each result — every one of those a separate
    /// IPC round trip. On a dense screen that is thousands of round trips, and it killed the
    /// companion outright: the launch log fills with `Find the Cell` until the stream closes.
    /// `snapshot()` fetches the whole tree in a single call and the walk happens in-process.
    ///
    /// Visibility is derived geometrically rather than from `isHittable`, which is itself a
    /// per-element round trip.
    private func matchableElements(in target: XCUIApplication, labeledOnly: Bool = false) -> [ElementSnapshot] {
        guard let root = snapshot(of: target) else { return [] }
        let viewport = visibleViewport(for: target)
        var named: [ElementSnapshot] = []
        var unlabeled: [ElementSnapshot] = []
        collectMatchable(root, depth: 0, viewport: viewport, into: &named, unlabeled: &unlabeled)
        guard !labeledOnly else { return named }
        // Named elements first, so the common case reads the same as it always did and the
        // frame-only entries are a tail the caller can ignore. Smallest first within the tail:
        // an icon button is a leaf a few dozen points across, while a full-bleed decorative
        // backdrop is the last thing anyone is looking for.
        return named + unlabeled.sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// Walks the tree once, splitting what it finds into elements a selector could name and
    /// elements only a coordinate can reach.
    ///
    /// The two are collected separately, each against its own cap, so a screen dense with
    /// decorative nodes cannot spend the whole result budget before the walk reaches the labeled
    /// controls deeper in the tree.
    private func collectMatchable(
        _ snapshot: XCUIElementSnapshot,
        depth: Int,
        viewport: CGRect,
        into results: inout [ElementSnapshot],
        unlabeled: inout [ElementSnapshot]
    ) {
        guard depth <= Self.maxMatchDepth,
              results.count < Self.maxMatchResults || unlabeled.count < Self.maxUnlabeledResults
        else { return }

        // Anything carrying an identifier or a label, rather than a set of element types: SwiftUI
        // reports nearly every node in a snapshot tree as `.other`, so a type filter here matches
        // nothing at all. The live queries this replaced sidestepped that by resolving through
        // accessibility traits, which a snapshot walk cannot see.
        let isNamed = !snapshot.identifier.isEmpty || !snapshot.label.isEmpty
        if isNamed, results.count < Self.maxMatchResults {
            results.append(element(from: snapshot, viewport: viewport))
        } else if !isNamed,
                  unlabeled.count < Self.maxUnlabeledResults,
                  isReachableUnlabeledLeaf(snapshot, viewport: viewport) {
            // An icon-only control — a close button drawn as a bare SF Symbol, anything inside a
            // third-party paywall — has neither identifier nor label, so no selector reaches it
            // and it used to be absent from every query result. Reporting its frame is the whole
            // difference between "amoo cannot see this button" and one tap at a known point.
            unlabeled.append(element(from: snapshot, viewport: viewport))
        }

        for child in snapshot.children {
            collectMatchable(child, depth: depth + 1, viewport: viewport, into: &results, unlabeled: &unlabeled)
        }
    }

    /// Whether an unnamed node is worth reporting: a leaf, on screen, and big enough to tap.
    ///
    /// Containers are excluded because their frame is their children's bounding box — tapping one
    /// hits whatever happens to sit at its centre. Sub-`minTappableSpan` nodes are separators and
    /// hairlines, not controls.
    private func isReachableUnlabeledLeaf(_ snapshot: XCUIElementSnapshot, viewport: CGRect) -> Bool {
        guard snapshot.children.isEmpty else { return false }
        let frame = snapshot.frame.standardized
        guard !frame.isNull, !frame.isEmpty,
              frame.width >= Self.minTappableSpan, frame.height >= Self.minTappableSpan
        else { return false }
        return isSnapshotVisible(snapshot, visibleFrame: snapshotVisibleFrame(snapshot), viewport: viewport)
    }

    private func element(from snapshot: XCUIElementSnapshot, viewport: CGRect) -> ElementSnapshot {
        let visibleFrame = snapshotVisibleFrame(snapshot)
        return ElementSnapshot(
            id: snapshot.identifier,
            label: snapshot.label,
            value: (snapshot.value as? String) ?? "",
            type: "\(snapshot.elementType)",
            frame: snapshot.frame,
            hitPoint: interactionPoint(frame: snapshot.frame, visibleFrame: visibleFrame, viewport: viewport),
            isEnabled: snapshot.isEnabled,
            isVisible: isSnapshotVisible(
                snapshot,
                visibleFrame: visibleFrame,
                viewport: viewport
            )
        )
    }

    /// A directional swipe centred on `frame`, travelling a quarter of its span.
    private func swipeFromCentre(of frame: CGRect, direction: ScrollDirection) {
        let dx = frame.width / 4
        let dy = frame.height / 4
        let (toX, toY): (CGFloat, CGFloat) = switch direction {
        case .up: (frame.midX, frame.midY - dy)
        case .down: (frame.midX, frame.midY + dy)
        case .left: (frame.midX - dx, frame.midY)
        case .right: (frame.midX + dx, frame.midY)
        }
        gestureCoordinate(x: frame.midX, y: frame.midY).press(
            forDuration: 0.05,
            thenDragTo: gestureCoordinate(x: toX, y: toY),
            withVelocity: .default,
            thenHoldForDuration: 0
        )
    }

    /// Bounds on a pathological tree, so a dense screen degrades into a truncated answer instead
    /// of taking the companion down with it.
    private static let maxMatchDepth = 40
    private static let maxMatchResults = 500

    /// Unlabeled leaves get a smaller budget of their own: they are a fallback for controls no
    /// selector can name, not a reason for a result set to double in size.
    private static let maxUnlabeledResults = 100

    /// Points below which an unnamed leaf is treated as decoration rather than a control. Apple's
    /// minimum touch target is 44pt; this is deliberately looser, since a small icon button often
    /// draws smaller than its hit area.
    private static let minTappableSpan: CGFloat = 12

    private func resolvedTextInput() -> XCUIElement? {
        let target = gestureTarget()
        let candidates = textInputCandidates(in: target)

        if let id = lastTappedElementID,
           let selected = candidates.first(where: { $0.identifier == id && $0.exists }) {
            return selected
        }

        if let label = lastTappedElementLabel,
           let selected = candidates.first(where: { $0.label == label && $0.exists }) {
            return selected
        }

        for candidate in candidates where candidate.exists && candidate.isHittable {
            return candidate
        }

        for candidate in candidates where candidate.exists {
            return candidate
        }

        return nil
    }

    private func clearLastTappedElement() {
        lastTappedElementID = nil
        lastTappedElementLabel = nil
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
