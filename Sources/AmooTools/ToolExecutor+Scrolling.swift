import AmooCore
import Foundation

/// The direction, travel and duration of a swipe aimed at a picked element.
struct PickedSwipe {
    var direction: Direction
    var distance: Double
    var durationMilliseconds: Int
}

extension DriverToolExecutor {
    /// The smallest finger travel that is a swipe. Anything shorter is a press that happens to move a
    /// pixel: a `scroll distance=0.4` long-pressed the screen centre, raised a keyboard and a loupe,
    /// and wedged the companion.
    static let minimumGestureDistance = 10.0

    /// A refusal for a `scroll` / `swipe_in_direction` too short to be a swipe, or `nil` if it is fine.
    static func gestureDistanceError(tool: String, distance: Double) -> ToolResult? {
        guard distance.isFinite, distance >= minimumGestureDistance else {
            return .error(
                "\(tool) failed: distance is points of finger travel and must be at least"
                    + " \(Int(minimumGestureDistance)) (got \(distance)); a shorter gesture is a press, not a"
                    + " swipe. Omit it for the 300-point default, or use scroll_to_element to bring a row on screen."
            )
        }
        return nil
    }

    /// Scrolls until the element is on screen, reversing once if the content ends first.
    ///
    /// Without it, reaching a below-the-fold row meant guessing a `scroll` distance and re-querying
    /// by hand. A target the hierarchy already holds off screen (lists keep rows near the viewport)
    /// is scrolled to directly, by its measured offset; one the hierarchy does not hold yet is paged
    /// toward, a viewport fraction at a time. "On screen" is the companion's own visibility verdict for the element, so
    /// a row
    /// clipped by the viewport counts as not yet there. So does a row under a bottom bar or
    /// other overlay, which the companion still reports as visible but a tap would miss. If scrolling
    /// never frees it, the covered row is still returned, as it was before that check. An attempt
    /// that leaves the screen unchanged means the content ended in that direction.
    func executeScrollToElement(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        guard let selector = try preferredSelector(arguments: arguments) else {
            return .error("At least one of id, label, or contains_text is required")
        }
        var direction = Direction.down
        if let raw = arguments["direction"] {
            guard let parsed = parseDirection(raw) else {
                return .error("Invalid direction: \(raw). Use up, down, left, or right.")
            }
            direction = parsed
        }
        let maxAttempts = min(max(arguments["max_attempts"].flatMap(Int.init) ?? 8, 1), 50)
        let distance = arguments["distance"].flatMap(Double.init)
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        let viewport = await screenViewport(driver: driver)

        let initialDirection = direction
        var reversedAfter: Int?
        var coveredMatch: (element: ElementInfo, scrolls: Int)?
        var before: ScreenLayout?
        for attempt in 0 ... maxAttempts {
            let found = try await resolveElement(
                selector: selector, driver: driver, appID: appID, pick: .first, missingIsNil: true
            )
            if let found, found.isVisible, found.isEnabled {
                if await isCoveredOnScreen(found, driver: driver, appID: appID) {
                    coveredMatch = (found, attempt)
                } else {
                    return scrollToElementSuccess(found, scrolls: attempt)
                }
            }
            guard attempt < maxAttempts else { break }
            // One read is enough before the first scroll: a screen still moving then can only read as
            // "moved", which delays detecting an end by a scroll; it never fakes one.
            if attempt == 0 {
                before = await screenLayout(driver: driver, appID: appID)
            }
            let move = Self.nextScroll(
                toward: found.flatMap { $0.isVisible ? nil : $0 },
                paging: direction,
                maximum: distance,
                viewport: viewport
            )
            try await driver.scroll(direction: move.direction, distance: move.distance)
            let after = await settledScreenLayout(driver: driver, appID: appID)
            if let before, let after, !after.contentMoved(since: before) {
                guard reversedAfter == nil else {
                    return scrollToElementGaveUp(
                        "reached both ends without finding the element.", coveredMatch: coveredMatch
                    )
                }
                reversedAfter = attempt + 1
                direction = direction.opposite
            }
            before = after
        }
        let trail = Self.scrollTrail(from: initialDirection, reversedAfter: reversedAfter)
        return scrollToElementGaveUp(
            "element not on screen after \(maxAttempts) scroll(s)\(trail).", coveredMatch: coveredMatch
        )
    }

    /// Share of the viewport one paging scroll travels: most of a screen, with enough overlap that a
    /// row clipped at one edge is whole after the scroll.
    static let pageFraction = 0.6

    /// Paging distance when the viewport is unknown.
    static let fallbackScrollDistance = 300.0

    /// The next scroll: straight at a `target` the hierarchy places off screen, by the distance
    /// between its centre and the viewport's, or a page in `direction` when there is no target.
    /// Either is capped at one page and at `maximum`, the caller's `distance`.
    static func nextScroll(
        toward target: ElementInfo?,
        paging direction: Direction,
        maximum: Double?,
        viewport: Rect?
    ) -> (direction: Direction, distance: Double) {
        let vertical = direction == .up || direction == .down
        var page = viewport.map { (vertical ? $0.height : $0.width) * pageFraction } ?? fallbackScrollDistance
        if let maximum {
            page = min(page, maximum)
        }
        guard let frame = target?.frame, let viewport else { return (direction, page) }
        let offset = vertical ? frame.centre.y - viewport.centre.y : frame.centre.x - viewport.centre.x
        let travel = min(abs(offset), page)
        guard travel >= minimumGestureDistance else { return (direction, page) }
        let toward: Direction = vertical ? (offset > 0 ? .down : .up) : (offset > 0 ? .right : .left)
        return (toward, travel)
    }

    /// The screen in the units element frames and scroll distances share: points on iOS, pixels on
    /// Android (its frames and swipes are both in pixels, so dp are scaled back up). Best effort: an
    /// unknown screen pages a fixed distance and never jumps.
    func screenViewport(driver: any PlatformDriver) async -> Rect? {
        await Self.withinBudget(milliseconds: 2000) {
            guard let screen = try? await driver.screenGeometry(),
                  screen.widthPoints > 0, screen.heightPoints > 0 else { return nil }
            let framesPerUnit = await (try? driver.elementGeometry())?.framesPerUnit ?? 1
            return Rect(
                x: 0,
                y: 0,
                width: screen.widthPoints * framesPerUnit,
                height: screen.heightPoints * framesPerUnit
            )
        }
    }

    /// Where the scrolling went, so a miss says whether either end of the content was ever reached.
    static func scrollTrail(from direction: Direction, reversedAfter: Int?) -> String {
        guard let reversedAfter else {
            return " (all \(direction.rawValue); the content never stopped moving, so no end was detected)"
        }
        return " (\(direction.rawValue) reached its end after \(reversedAfter), then \(direction.opposite.rawValue))"
    }

    /// How long a scroll may keep the screen moving before its fingerprint is taken as it stands.
    static let scrollSettleBudgetMilliseconds = 1200

    /// The pause between two fingerprint reads while waiting for a scroll to settle.
    static let scrollSettlePollMilliseconds = 120

    /// The screen layout once two consecutive reads show no movement, or the last read when the
    /// budget runs out.
    ///
    /// A read taken right after the finger lifts catches the list mid-flight: at either end, iOS
    /// rubber-bands the content past the edge and animates it back, and Android stretches and
    /// relaxes it. Compared unsettled, a scroll that hit the end never looked like "nothing moved",
    /// so `scroll_to_element` never reversed and spent every attempt pushing against the end of
    /// a SwiftUI List whose target sat the other way.
    func settledScreenLayout(driver: any PlatformDriver, appID: String?) async -> ScreenLayout? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Self.scrollSettleBudgetMilliseconds))
        var readStarted = clock.now
        var previous = await screenLayout(driver: driver, appID: appID)
        while clock.now < deadline {
            // Reads are the spacing: on a device one takes about a quarter of a second, which is
            // already longer than the poll interval, so only a faster read waits out the rest.
            try? await Task.sleep(until: readStarted.advanced(by: .milliseconds(Self.scrollSettlePollMilliseconds)))
            readStarted = clock.now
            let current = await screenLayout(driver: driver, appID: appID)
            if let previous, let current, !current.contentMoved(since: previous) {
                return current
            }
            previous = current
        }
        return previous
    }

    /// The result when scrolling cannot do better: a row that was visible but covered is still
    /// returned, anything else is the failure `reason`.
    private func scrollToElementGaveUp(
        _ reason: String,
        coveredMatch: (element: ElementInfo, scrolls: Int)?
    ) -> ToolResult {
        guard let coveredMatch else { return .error("scroll_to_element failed: \(reason)") }
        return scrollToElementSuccess(coveredMatch.element, scrolls: coveredMatch.scrolls)
    }

    private func scrollToElementSuccess(_ element: ElementInfo, scrolls: Int) -> ToolResult {
        .success(
            "Element [\(element.id)] \(element.label) is on screen after \(scrolls) scroll(s)",
            structuredContent: .object(["scrolls": .int(scrolls), "element_id": .string(element.id)])
        )
    }

    /// Whether the hierarchy shows another control painted over the element's tap point or a
    /// container clipping it. Best effort: a platform without hierarchy checks, or a read that does not
    /// finish in time, reports it uncovered.
    private func isCoveredOnScreen(_ element: ElementInfo, driver: any PlatformDriver, appID: String?) async -> Bool {
        guard let point = element.hitPoint ?? element.frame?.centre,
              let hierarchy = await Self.withinBudget(milliseconds: 1500, {
                  try? await driver.getViewHierarchy(appID: appID)
              })
        else { return false }
        return TapHittability.block(for: element, at: point, in: hierarchy) != nil
    }

    /// Swipes from the centre of the match `pick` names, for elements the device cannot tell apart by
    /// selector alone (the companion refuses an ambiguous `element_id`). The step is recorded with its
    /// `element_id` and pick, so generated code scopes the gesture to the same match.
    func swipePickedElement(
        _ selector: ElementSelector,
        pick: ElementPick,
        gesture: PickedSwipe,
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> ToolResult {
        let (direction, distance, duration) = (gesture.direction, gesture.distance, gesture.durationMilliseconds)
        guard let matched = try await resolveElement(selector: selector, driver: driver, appID: appID, pick: pick),
              let start = matched.hitPoint ?? matched.frame?.centre
        else {
            return .error("swipe_in_direction failed: no element matched, or it reports no position to swipe from")
        }
        let (dx, dy): (Double, Double) = switch direction {
        case .up: (0, -distance)
        case .down: (0, distance)
        case .left: (-distance, 0)
        case .right: (distance, 0)
        }
        try await driver.swipe(
            from: start,
            to: Point(x: start.x + dx, y: start.y + dy),
            duration: Duration(milliseconds: duration)
        )
        return .success("Swiped \(direction.rawValue) by \(distance) pts from [\(matched.id)] \(matched.label)")
    }

    /// What is on screen, as ids, labels and positions, for telling whether a scroll moved anything.
    /// The screen *summary* cannot stand in: on Android it holds only status-bar text, which never
    /// changes while a list scrolls.
    func screenLayout(driver: any PlatformDriver, appID: String?) async -> ScreenLayout? {
        guard let elements = try? await driver.findElements(ElementSelector(), appID: appID) else { return nil }
        return ScreenLayout(elements.prefix(300))
    }

    /// Hides the keyboard using one unambiguous, explicitly named dismissal button, or Back on Android.
    ///
    /// Return can submit a form, Escape can close a sheet, and a generic Done button can save it.
    /// Swiping can dismiss the sheet too, so none of those are default fallbacks; `method=return`
    /// opts in to the return key. Android's Back closes the keyboard first and nothing else while it
    /// is shown, so it is safe there.
    func executeDismissKeyboard(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        let method = arguments["method"] ?? "auto"
        guard ["auto", "return"].contains(method) else {
            throw ToolExecutionError(code: "invalid_argument", message: "method must be auto or return")
        }
        guard try await driver.isKeyboardVisible() else {
            return .success("Keyboard was not visible", structuredContent: .object([
                "dispatch_status": .string("not_dispatched"), "postcondition_verified": .bool(true)
            ]))
        }
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        var candidates: [ElementInfo] = []
        for label in ["Hide keyboard", "Dismiss keyboard"] {
            let elements = try await driver.findElements(ElementSelector(label: label), appID: appID)
            candidates += elements.filter {
                $0.label == label && $0.type == .button && $0.isVisible && $0.isEnabled
                    && ($0.hitPoint ?? $0.frame?.centre) != nil
            }
        }
        guard candidates.count == 1, let button = candidates.first,
              let point = button.hitPoint ?? button.frame?.centre else {
            return try await dismissKeyboardWithoutAButton(method: method, driver: driver)
        }
        try await driver.tap(at: point)
        if await keyboardIsGone(driver) {
            return .success("Keyboard dismissed with the '\(button.label)' button")
        }
        return .error(
            "dismiss_keyboard failed: the keyboard is still visible after tapping '\(button.label)'."
                + " No further action was taken. Inspect the screen and use an explicit app control."
        )
    }

    /// No dedicated control: Back on Android, the return key when asked for, otherwise a refusal that
    /// names both options.
    private func dismissKeyboardWithoutAButton(method: String, driver: any PlatformDriver) async throws -> ToolResult {
        let platform = try? await driver.deviceInfo().platform
        let (action, description): (() async throws -> Void, String)
        if method == "return" {
            // A hardware Return left a SwiftUI search keyboard up; tapping the keyboard's own key closes it.
            if let key = try await keyboardReturnKey(driver: driver), let point = key.hitPoint ?? key.frame?.centre {
                (action, description) = ({ try await driver.tap(at: point) }, "the keyboard's '\(key.label)' key")
            } else {
                (action, description) = ({ try await driver.pressKey(.returnKey, modifiers: []) }, "the return key")
            }
        } else if platform == .android {
            (action, description) = ({ try await driver.pressBack() }, "Back")
        } else {
            return .error(
                "dismiss_keyboard failed: no unambiguous keyboard-dismiss control was found."
                    + " No action was taken. If pressing the keyboard's return key is acceptable here (a search"
                    + " field submits its query), call dismiss_keyboard method=return; otherwise use tap_element"
                    + " with an explicit app control."
            )
        }
        try await action()
        if await keyboardIsGone(driver) {
            return .success("Keyboard dismissed with \(description)")
        }
        return .error(
            "dismiss_keyboard failed: the keyboard is still visible after \(description)."
                + " No further action was taken. Inspect the screen and use an explicit app control."
        )
    }

    /// The software keyboard's return key ("search", "go", "done"…). Keyboard keys report a capitalised
    /// identifier and the same word in lower case as their label, which an app's own Done button does not.
    private func keyboardReturnKey(driver: any PlatformDriver) async throws -> ElementInfo? {
        let identifiers: Set = ["Return", "Search", "Go", "Done", "Next", "Send", "Join", "Route", "Continue"]
        let keys = try await driver.findElements(ElementSelector()).filter {
            identifiers.contains($0.id) && $0.label == $0.id.lowercased() && $0.isVisible
        }
        return keys.count == 1 ? keys.first : nil
    }

    private func keyboardIsGone(_ driver: any PlatformDriver) async -> Bool {
        for _ in 0 ..< 3 {
            try? await Task.sleep(for: .milliseconds(250))
            if await (try? driver.isKeyboardVisible()) == false {
                return true
            }
        }
        return false
    }
}

extension Direction {
    var opposite: Self {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }
}

/// Where each element sat on one read of the screen, keyed by id, label and occurrence.
struct ScreenLayout: Equatable {
    /// Points an element may shift without counting as moved: layout rounding, not scrolling.
    static let tolerance = 2.0

    /// Elements that must move, or appear or vanish, before the content counts as moved. A scroll
    /// shifts every row it carries; a control animating its own press or selection state shifts
    /// only itself and its label, and must not read as an endless scroll.
    static let movedElementThreshold = 3

    let positions: [String: Point]

    init(_ elements: some Sequence<ElementInfo>) {
        var positions: [String: Point] = [:]
        var occurrences: [String: Int] = [:]
        for element in elements {
            let base = "\(element.id)|\(element.label)"
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            positions["\(base)|\(occurrence)"] = Point(x: element.frame?.x ?? -1, y: element.frame?.y ?? -1)
        }
        self.positions = positions
    }

    /// Whether enough of the screen changed between `earlier` and this read to call it a scroll.
    /// The threshold drops to the element count on a screen with fewer elements than it.
    func contentMoved(since earlier: Self) -> Bool {
        var changed = 0
        for (key, point) in positions {
            guard let previous = earlier.positions[key] else {
                changed += 1
                continue
            }
            if abs(point.x - previous.x) > Self.tolerance || abs(point.y - previous.y) > Self.tolerance {
                changed += 1
            }
        }
        changed += earlier.positions.keys.count(where: { positions[$0] == nil })
        let needed = min(Self.movedElementThreshold, max(1, max(positions.count, earlier.positions.count)))
        return changed >= needed
    }
}
