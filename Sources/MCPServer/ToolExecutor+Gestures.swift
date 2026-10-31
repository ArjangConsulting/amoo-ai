import AmooCore
import MCP

/// `drag` and `pinch`: the gestures whose ends can each be an element or a point.
extension DriverToolExecutor {
    /// Default hold at the drag source. Above both platforms' drag-and-drop lift delay (~500ms), so an
    /// unqualified drag picks the item up rather than scrolling the list under it.
    static let defaultDragHoldMilliseconds = 800
    static let defaultDragDurationMilliseconds = 1000

    /// Where one end of a gesture lands, and the element it was resolved from when one was named.
    struct GestureEnd {
        let point: Point
        let element: ElementInfo?

        var name: String {
            guard let element else { return "(\(geometryNumber(point.x)), \(geometryNumber(point.y)))" }
            let name = preferredElementName(label: element.label, id: element.id) ?? element.id
            return "'\(name)' at (\(geometryNumber(point.x)), \(geometryNumber(point.y)))"
        }
    }

    func executeDrag(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        let source = try await gestureEnd(.dragSource, arguments: arguments, driver: driver, appID: appID)
        let target = try await gestureEnd(.dragTarget, arguments: arguments, driver: driver, appID: appID)
        let hold = try milliseconds(arguments, key: "hold_ms", default: Self.defaultDragHoldMilliseconds)
        let duration = try milliseconds(arguments, key: "duration_ms", default: Self.defaultDragDurationMilliseconds)

        if let element = source.element {
            let checks = TapChecks(hittable: hittableCheck(arguments: arguments), effect: .off)
            let preflight = try await tapPreflight(
                matched: element,
                point: source.point,
                checks: checks,
                driver: driver,
                appID: appID,
                gesture: ("drag", "drag")
            )
            if let refusal = preflight.refusal {
                return refusal
            }
        }
        try await driver.drag(
            from: source.point,
            to: target.point,
            duration: Duration(milliseconds: duration),
            holdDuration: Duration(milliseconds: hold)
        )
        return .success(
            "Dragged \(source.name) onto \(target.name) pts (held \(hold)ms, moved over \(duration)ms)."
                + " Verify the drop with an assertion.",
            structuredContent: .object([
                "from": Self.pointValue(source.point),
                "to": Self.pointValue(target.point),
                "hold_ms": .int(hold),
                "duration_ms": .int(duration)
            ])
        )
    }

    func executePinch(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        guard let rawScale = arguments["scale"] else {
            return .error("Missing required argument: scale (above 1 zooms in, below 1 zooms out)")
        }
        guard let scale = Double(rawScale), scale.isFinite, scale > 0, scale != 1 else {
            return .error("pinch scale must be a positive number other than 1 (above 1 zooms in, below 1 zooms out);"
                + " got '\(rawScale)'")
        }
        let velocity = try arguments["velocity"].map { raw -> Double in
            guard let value = Double(raw), value.isFinite, value >= 0 else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "velocity must be a non-negative number (scale change per second), got '\(raw)'."
                )
            }
            return value
        } ?? 0
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        let hasElement = ["id", "label", "contains_text"].contains { arguments[$0]?.isEmpty == false }
        let hasPoint = arguments["x"] != nil || arguments["y"] != nil
        let centre: GestureEnd
        if hasElement || hasPoint {
            centre = try await gestureEnd(.pinchCentre, arguments: arguments, driver: driver, appID: appID)
        } else {
            let screen = try await driver.screenGeometry()
            centre = GestureEnd(point: Point(x: screen.widthPoints / 2, y: screen.heightPoints / 2), element: nil)
        }
        try await driver.pinch(center: centre.point, scale: scale, velocity: velocity, bounds: centre.element?.frame)
        let zoom = scale > 1 ? "in" : "out"
        return .success(
            "Pinched to zoom \(zoom) (scale \(geometryNumber(scale))) around \(centre.name) pts.",
            structuredContent: .object([
                "center": Self.pointValue(centre.point),
                "scale": .double(scale)
            ])
        )
    }

    /// Which arguments name one end of a gesture.
    struct GestureEndKeys {
        static let dragSource = Self(prefix: "", pointKeys: ("from_x", "from_y"), role: "source")
        static let dragTarget = Self(prefix: "to_", pointKeys: ("to_x", "to_y"), role: "target")
        static let pinchCentre = Self(prefix: "", pointKeys: ("x", "y"), role: "element")

        /// Prepended to the selector keys (`id`, `label`, …).
        let prefix: String
        let pointKeys: (x: String, y: String)
        /// How error messages name this end.
        let role: String
    }

    /// One end of a gesture: an element named by `id`/`label`/`contains_text` (after the prefix), or a
    /// point. Naming both, or neither, is an error, since either way it is unclear what was meant.
    private func gestureEnd(
        _ keys: GestureEndKeys,
        arguments: [String: String],
        driver: any PlatformDriver,
        appID: String?
    ) async throws -> GestureEnd {
        let (prefix, pointKeys, role) = (keys.prefix, keys.pointKeys, keys.role)
        var selectorArguments: [String: String] = [:]
        for key in ["id", "label", "contains_text", "parent_id", "index", "first"] {
            selectorArguments[key] = arguments[prefix + key]
        }
        let selector = try preferredSelector(arguments: selectorArguments)
        let rawX = arguments[pointKeys.x]
        let rawY = arguments[pointKeys.y]
        let selectorNames = "\(prefix)id/\(prefix)label/\(prefix)contains_text"
        switch (selector, rawX, rawY) {
        case let (selector?, nil, nil):
            let pick = try ElementPick.parse(selectorArguments)
            guard let element = try await resolveElement(selector: selector, driver: driver, appID: appID, pick: pick),
                  let point = element.hitPoint ?? element.frame?.centre
            else {
                throw ToolExecutionError(
                    code: "element_not_found",
                    message: "No \(role) element matched \(Self.describeConstraints(selector)), or it reports no"
                        + " position. Check find_elements, or scroll it into view first."
                )
            }
            return GestureEnd(point: point, element: element)
        case let (nil, rawX?, rawY?):
            guard let x = Double(rawX), let y = Double(rawY) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "\(pointKeys.x)/\(pointKeys.y) must be numbers, got '\(rawX)', '\(rawY)'."
                )
            }
            let converted = try await convertToPoints(x: x, y: y, unit: arguments["unit"], driver: driver)
            return GestureEnd(point: Point(x: converted.x, y: converted.y), element: nil)
        case (_?, _, _):
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Name the \(role) by \(selectorNames) or by \(pointKeys.x)/\(pointKeys.y), not both."
            )
        default:
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Missing \(role): pass \(selectorNames) (preferred), or both \(pointKeys.x)"
                    + " and \(pointKeys.y)."
            )
        }
    }

    private func milliseconds(_ arguments: [String: String], key: String, default value: Int) throws -> Int {
        guard let raw = arguments[key] else { return value }
        guard let parsed = Int(raw), (0 ... 60000).contains(parsed) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "\(key) must be a whole number of milliseconds from 0 to 60000, got '\(raw)'."
            )
        }
        return parsed
    }

    private static func pointValue(_ point: Point) -> Value {
        .object(["x": .double(point.x), "y": .double(point.y)])
    }
}
