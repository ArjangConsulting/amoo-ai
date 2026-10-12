import AmooCore
import Foundation

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
    /// by hand. "On screen" is the companion's own visibility verdict for the element, so a row
    /// clipped by the viewport counts as not yet there. An attempt that leaves the screen unchanged
    /// means the content ended in that direction.
    func executeScrollToElement(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        guard let selector = preferredSelector(arguments: arguments) else {
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
        let distance = arguments["distance"].flatMap(Double.init) ?? 300
        let appID = queryScopeAppID(arguments: arguments, driver: driver)

        var reversed = false
        for attempt in 0 ... maxAttempts {
            if let found = try await resolveElement(
                selector: selector, driver: driver, appID: appID, pick: .first, missingIsNil: true
            ), found.isVisible, found.isEnabled {
                return .success(
                    "Element [\(found.id)] \(found.label) is on screen after \(attempt) scroll(s)",
                    structuredContent: .object(["scrolls": .int(attempt), "element_id": .string(found.id)])
                )
            }
            guard attempt < maxAttempts else { break }
            let before = await screenFingerprint(driver: driver, appID: appID)
            try await driver.scroll(direction: direction, distance: distance)
            let after = await screenFingerprint(driver: driver, appID: appID)
            if let before, before == after {
                guard !reversed else {
                    return .error("scroll_to_element failed: reached both ends without finding the element.")
                }
                reversed = true
                direction = direction.opposite
            }
        }
        return .error("scroll_to_element failed: element not on screen after \(maxAttempts) scroll(s).")
    }

    /// What is on screen, as ids, labels and vertical positions. Scrolling moves the positions, so two
    /// equal fingerprints mean the content did not move. The screen *summary* cannot stand in: on
    /// Android it holds only status-bar text, which never changes while a list scrolls.
    func screenFingerprint(driver: any PlatformDriver, appID: String?) async -> String? {
        guard let elements = try? await driver.findElements(ElementSelector(), appID: appID) else { return nil }
        return elements.prefix(300).map { "\($0.id)|\($0.label)|\(Int($0.frame?.y ?? -1))|\(Int($0.frame?.x ?? -1))" }
            .joined(separator: "\n")
    }

    /// Hides the keyboard by the gentlest means that works and says which one did.
    ///
    /// `press_key return` reports success on a decimal or number pad, which has no Return key, and
    /// leaves the keyboard up. This tries Return, then a Hide/Done button, then a swipe down.
    func executeDismissKeyboard(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        guard try await driver.isKeyboardVisible() else {
            return .success("Keyboard was not visible")
        }
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        if let key = KeyboardKey(name: "return") {
            try? await driver.pressKey(key, modifiers: [])
            if await keyboardIsGone(driver) {
                return .success("Keyboard dismissed with Return")
            }
        }
        for label in ["Hide keyboard", "Done", "Dismiss keyboard"] {
            let buttons = await (try? driver.findElements(ElementSelector(label: label), appID: appID)) ?? []
            if let button = buttons.first(where: { $0.isVisible && $0.isEnabled }),
               let point = button.hitPoint ?? button.frame?.centre {
                try await driver.tap(at: point)
                if await keyboardIsGone(driver) {
                    return .success("Keyboard dismissed with the '\(label)' button")
                }
            }
        }
        try await driver.swipe(direction: .down, distance: 200, duration: Duration(milliseconds: 300), element: nil)
        if await keyboardIsGone(driver) {
            return .success("Keyboard dismissed by swiping down")
        }
        return .error(
            "dismiss_keyboard failed: the keyboard is still visible after Return, a Hide/Done button and a swipe."
        )
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
