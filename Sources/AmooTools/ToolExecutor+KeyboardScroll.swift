import AmooCore
import Foundation

/// With the keyboard up, a scroll through the screen's centre lands on keys and moves nothing, and one
/// started in the area above it can begin in a header that does not scroll. Scrolls drag inside the
/// scrollable container's frame, clipped above the keyboard.
extension DriverToolExecutor {
    /// Where scrolling happens: the screen, or with the keyboard up the scroll view holding `targetID`
    /// (else the largest one) clipped above the keyboard. `aboveKeyboard` says which.
    func scrollArea(
        driver: any PlatformDriver,
        appID: String?,
        targetID: String? = nil
    ) async -> (viewport: Rect?, aboveKeyboard: Bool) {
        let screen = await screenViewport(driver: driver)
        guard await (try? driver.isKeyboardVisible()) == true else { return (screen, false) }
        // Right after typing, a read can come back without the keyboard's window; it returns a moment later.
        for attempt in 0 ..< 2 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard let root = await Self.withinBudget(milliseconds: 1500, {
                try? await driver.getViewHierarchy(appID: appID)
            }) else { continue }
            if let area = Self.keyboardScrollArea(in: root, screen: screen, targetID: targetID) {
                return (area, true)
            }
        }
        // Still no keyboard in the tree: its keys keep stable identifiers whatever the language. The
        // first keyboard after a launch is still sliding in, so its shift key is read until it rests.
        guard let shift = await restingShiftKey(driver: driver, appID: appID), let screen else {
            return (screen, false)
        }
        let top = shift.y - Self.keyboardHeightAboveShiftKey
        guard top - screen.y >= Self.minimumScrollArea else { return (screen, false) }
        return (Rect(x: screen.x, y: screen.y, width: screen.width, height: top - screen.y), true)
    }

    /// The keyboard's shift key once two reads 150 ms apart agree on its position, or nil.
    private func restingShiftKey(driver: any PlatformDriver, appID: String?) async -> Rect? {
        var previous: Rect?
        for attempt in 0 ..< 8 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(150))
            }
            let keys = await Self.withinBudget(milliseconds: 1500) {
                try? await driver.findElements(ElementSelector(id: "shift"), appID: appID)
            } ?? []
            guard let frame = keys.compactMap(\.frame).first else { return nil }
            if let previous, abs(previous.y - frame.y) < 1 {
                return frame
            }
            previous = frame
        }
        return nil
    }

    /// How far a phone keyboard reaches above its shift key: two rows of keys and the suggestion bar.
    /// Generous, so the area it leaves is always above the keys.
    static let keyboardHeightAboveShiftKey = 190.0

    /// The scrollable area above the keyboard in `root`, or nil when the keyboard is not exposed or too
    /// little of the container is left above it. iOS names the keyboard's layout container
    /// `UIKeyboardLayout…` whatever the keyboard's language.
    nonisolated static func keyboardScrollArea(in root: ViewNode, screen: Rect?, targetID: String?) -> Rect? {
        var keyboard: Rect?
        var containers: [Rect] = []
        var targetContainer: Rect?
        var visited = 0
        func walk(_ node: ViewNode, container: Rect?, depth: Int) {
            visited += 1
            guard depth < 256, visited < 20000 else { return }
            if keyboard == nil, node.id.hasPrefix("UIKeyboardLayout") {
                keyboard = node.frame ?? union(node.children.compactMap(\.frame))
                return
            }
            var enclosing = container
            if [.scrollView, .table, .collectionView].contains(node.type), let frame = node.frame {
                containers.append(frame)
                enclosing = frame
            }
            if targetContainer == nil, let targetID, node.id == targetID {
                targetContainer = enclosing
            }
            for child in node.children {
                walk(child, container: enclosing, depth: depth + 1)
            }
        }
        walk(root, container: nil, depth: 0)
        guard let keyboard else { return nil }
        let largest = containers.filter { $0.y < keyboard.y }.max { $0.width * $0.height < $1.width * $1.height }
        // The target's own container can be a nested or mostly hidden one; the first candidate with room
        // above the keyboard wins.
        for base in [targetContainer, largest, screen].compactMap(\.self) {
            let bounded = screen.map { intersection(base, $0) } ?? base
            let bottom = min(bounded.y + bounded.height, keyboard.y)
            if bottom - bounded.y >= minimumScrollArea, bounded.width >= minimumScrollArea {
                return Rect(x: bounded.x, y: bounded.y, width: bounded.width, height: bottom - bounded.y)
            }
        }
        return nil
    }

    /// The smallest height left above the keyboard that is still worth dragging in.
    static let minimumScrollArea = 120.0

    nonisolated static func intersection(_ first: Rect, _ second: Rect) -> Rect {
        let minX = max(first.x, second.x)
        let minY = max(first.y, second.y)
        let maxX = min(first.x + first.width, second.x + second.width)
        let maxY = min(first.y + first.height, second.y + second.height)
        return Rect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    nonisolated static func union(_ frames: [Rect]) -> Rect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { box, frame in
            let minX = min(box.x, frame.x)
            let minY = min(box.y, frame.y)
            let maxX = max(box.x + box.width, frame.x + frame.width)
            let maxY = max(box.y + box.height, frame.y + frame.height)
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// Scrolls like `driver.scroll`, or, given an `area`, drags through that area's centre the way the
    /// companion's own scroll drags through the screen's.
    func scroll(
        _ direction: Direction,
        by distance: Double,
        within area: Rect?,
        driver: any PlatformDriver
    ) async throws {
        guard let area else {
            try await driver.scroll(direction: direction, distance: distance)
            return
        }
        let vertical = direction == .up || direction == .down
        let travel = min(distance, (vertical ? area.height : area.width) * 0.7)
        let centre = area.centre
        let (dx, dy): (Double, Double) = switch direction {
        case .down: (0, -travel)
        case .up: (0, travel)
        case .right: (-travel, 0)
        case .left: (travel, 0)
        }
        try await driver.drag(
            from: Point(x: centre.x - dx / 2, y: centre.y - dy / 2),
            to: Point(x: centre.x + dx / 2, y: centre.y + dy / 2),
            duration: Duration(milliseconds: 400),
            holdDuration: Duration(milliseconds: 50)
        )
    }
}
