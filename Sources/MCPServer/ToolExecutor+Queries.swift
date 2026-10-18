// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
import TestSession

/// Validated pagination shared by query tools. Cursors must be reused with the same query.
struct QueryPage {
    let offset: Int
    let limit: Int

    init(_ arguments: [String: String], defaultLimit: Int = 50) throws {
        offset = try Self.integer(arguments["offset"], fallback: 0, range: 0 ... 1_000_000)
        limit = try Self.integer(arguments["limit"], fallback: defaultLimit, range: 1 ... 2000)
    }

    static func integer(_ raw: String?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw), range.contains(value) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Numeric argument is outside its allowed range."
            )
        }
        return value
    }
}

extension DriverToolExecutor {
    /// A `swipe_in_direction` with a start point is the coordinate `swipe` it describes. Executing
    /// and recording it as that `swipe` lets the recorder bind the start point to the row under it,
    /// so codegen still emits an element-scoped gesture instead of a screen-centre swipe.
    func canonicalGesture(tool: String, arguments: [String: String]) async throws -> (String, [String: String]) {
        guard tool == "swipe_in_direction", arguments["from_x"] != nil || arguments["from_y"] != nil else {
            return (tool, arguments)
        }
        guard let x = arguments["from_x"].flatMap(Double.init), let y = arguments["from_y"].flatMap(Double.init) else {
            throw ToolExecutionError(code: "invalid_argument", message: "from_x and from_y must be passed together.")
        }
        guard arguments["element_id"] == nil, arguments["element_label"] == nil else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Pass either from_x/from_y or element_id/element_label, not both."
            )
        }
        guard let direction = arguments["direction"].flatMap(parseDirection) else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Invalid direction: \(arguments["direction"] ?? ""). Use up, down, left, or right."
            )
        }
        let driver = try await resolveDriver(arguments: arguments)
        let start = try await convertToPoints(x: x, y: y, unit: arguments["unit"], driver: driver)
        let distance = arguments["distance"].flatMap(Double.init) ?? 300
        let (dx, dy): (Double, Double) = switch direction {
        case .up: (0, -distance)
        case .down: (0, distance)
        case .left: (-distance, 0)
        case .right: (distance, 0)
        }
        var swipe = arguments
        swipe["direction"] = nil
        swipe["distance"] = nil
        swipe["from_x"] = String(start.x)
        swipe["from_y"] = String(start.y)
        swipe["to_x"] = String(start.x + dx)
        swipe["to_y"] = String(start.y + dy)
        swipe["unit"] = "points"
        swipe["duration_ms"] = arguments["duration_ms"] ?? "400"
        return ("swipe", swipe)
    }

    func normalizedCoordinates(tool: String, arguments: [String: String]) async throws -> [String: String] {
        guard ["tap", "double_tap", "long_press", "swipe"].contains(tool),
              let unit = arguments["unit"], unit != "points" else { return arguments }
        let driver = try await resolveDriver(arguments: arguments)
        let pairs = tool == "swipe" ? [("from_x", "from_y"), ("to_x", "to_y")] : [("x", "y")]
        var normalized = arguments
        for (xKey, yKey) in pairs {
            guard let x = arguments[xKey].flatMap(Double.init), let y = arguments[yKey].flatMap(Double.init) else {
                throw ToolExecutionError(code: "invalid_argument", message: "Coordinates must be numbers.")
            }
            let point = try await convertToPoints(x: x, y: y, unit: unit, driver: driver)
            normalized[xKey] = String(point.x)
            normalized[yKey] = String(point.y)
        }
        normalized["unit"] = "points"
        return normalized
    }

    func executeFindElements(arguments: [String: String], driver: any PlatformDriver) async throws -> ToolResult {
        let page = try QueryPage(arguments)
        let selector = ElementSelector(
            id: arguments["id"], label: arguments["label"], containsText: arguments["contains_text"],
            description: arguments["description"],
            parentSelector: arguments["parent_id"].map { .selector(ElementSelector(id: $0)) },
            labeledOnly: boolArgument(arguments["labeled_only"]) ?? false
        )
        var elements = try await findScopedElements(
            selector,
            driver: driver,
            appID: queryScopeAppID(arguments: arguments, driver: driver)
        )
        elements = try validateGeometry(elements)
        // `index` / `first` narrow the matches to the one a later tap or assertion would pick. That
        // index counts the device's own order, so noise is never filtered out from under it.
        let pick = try ElementPick.parse(arguments)
        var hiddenNoise = 0
        if let pick {
            elements = try pickElement(elements, pick: pick, missingIsNil: true).map { [$0] } ?? []
        } else if boolArgument(arguments["include_noise"]) != true, Self.listsEverything(arguments) {
            let kept = Self.removingNoise(elements)
            hiddenNoise = elements.count - kept.count
            elements = kept
        }
        let selected = Array(elements.dropFirst(page.offset).prefix(page.limit))
        let rows = selected.map { elementFields($0, includeValue: true) }
        let descriptions = selected.map { Self.describe($0, includeValue: true) }
        let recordedDescriptions = selected.map { Self.describe($0, includeValue: false) }
        let next = page.offset + selected.count
        var fields: [String: Value] = [
            "elements": .array(rows), "total": .int(elements.count), "has_more": .bool(next < elements.count)
        ]
        if next < elements.count {
            fields["next_offset"] = .int(next)
        }
        if hiddenNoise > 0 {
            fields["hidden_noise"] = .int(hiddenNoise)
        }
        let more = next < elements.count ? "\nMore results: offset=\(next)" : ""
        let hidden = hiddenNoise > 0 ? "\n\(hiddenNoise) noise element(s) hidden; include_noise=true lists them." : ""
        let header = "Found \(elements.count) element(s):\n"
        return ToolResult(
            content: header + descriptions.joined(separator: "\n") + more + hidden,
            structuredContent: .object(fields),
            observedElements: selected.map { element in
                RecordedElement(
                    id: element.id.isEmpty ? nil : element.id,
                    label: element.label.isEmpty ? nil : element.label,
                    elementType: element.type?.rawValue,
                    frame: element.frame.map { RecordedRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                    hitPoint: element.hitPoint.map { RecordedPoint(x: $0.x, y: $0.y) },
                    isSelected: element.isSelected
                )
            },
            // A field's current text reaches the caller but is not written to the session report.
            recordedContent: header + recordedDescriptions.joined(separator: "\n") + more + hidden
        )
    }

    /// One line per element: identity, then the current value, then where it is.
    static func describe(_ element: ElementInfo, includeValue: Bool) -> String {
        let point = element.hitPoint ?? element.frame?.centre
        let position = point.map { " hitPoint: (\(geometryNumber($0.x)),\(geometryNumber($0.y))) pts" } ?? ""
        let size = element.frame.map { " \(geometryNumber($0.width))x\(geometryNumber($0.height))" } ?? ""
        let identity = element.id.isEmpty && element.label.isEmpty
            ? "[unlabeled] \(element.type?.rawValue ?? "element")"
            : "[\(element.id.prefix(240))] \(element.label.prefix(240))"
        let value = includeValue ? displayValue(of: element).map { " value=\"\($0)\"" } ?? "" : ""
        return identity + value + position + size
    }

    /// The element's current value as one line, or `nil` when there is none to show. Secure fields
    /// never show theirs.
    static func displayValue(of element: ElementInfo) -> String? {
        guard !element.isSecureTextEntry, let value = element.value, !value.isEmpty else { return nil }
        return String(value.prefix(240))
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func elementFields(_ element: ElementInfo, includeValue: Bool = false) -> Value {
        var fields: [String: Value] = [
            "id": .string(element.id), "label": .string(String(element.label.prefix(240))),
            "type": .string(element.type?.rawValue ?? "other"),
            "visible": .bool(element.isVisible), "enabled": .bool(element.isEnabled)
        ]
        if let selected = element.isSelected {
            fields["selected"] = .bool(selected)
        }
        if includeValue, !element.isSecureTextEntry, let value = element.value, !value.isEmpty {
            fields["value"] = .string(String(value.prefix(240)))
        }
        if let point = element.hitPoint ?? element.frame?.centre {
            fields["x"] = .double(point.x)
            fields["y"] = .double(point.y)
        }
        return .object(fields)
    }
}

extension DriverToolExecutor {
    func paginationFields(key: String, rows: [Value], total: Int, page: QueryPage) -> Value {
        let next = page.offset + rows.count
        var fields: [String: Value] = [key: .array(rows), "total": .int(total), "has_more": .bool(next < total)]
        if next < total {
            fields["next_offset"] = .int(next)
        }
        return .object(fields)
    }

    func renderHierarchy(_ root: ViewNode, arguments: [String: String]) throws -> ToolResult {
        let limit = try QueryPage.integer(arguments["max_nodes"], fallback: 200, range: 1 ... 2000)
        var stack: [(ViewNode, Int)] = [(root, 0)]
        var lines: [String] = []
        while let (node, depth) = stack.popLast() {
            if lines.count == limit {
                return .success(lines.joined(separator: "\n") + "\n[truncated: refine bundle_id or increase max_nodes]")
            }
            var leaf = node
            leaf.children = []
            leaf.label = String(leaf.label.prefix(240))
            leaf.value = leaf.value.map { String($0.prefix(240)) }
            lines.append(renderViewNode(leaf, indent: min(depth, 30)))
            stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
        }
        return .success(lines.joined(separator: "\n"))
    }
}

// swiftlint:enable multiline_arguments
