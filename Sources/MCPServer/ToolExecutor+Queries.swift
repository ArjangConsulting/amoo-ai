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
        let elements = try await driver.findElements(
            selector,
            appID: queryScopeAppID(arguments: arguments, driver: driver)
        )
        let selected = Array(elements.dropFirst(page.offset).prefix(page.limit))
        let rows = selected.map(elementFields)
        let descriptions = selected.map { element in
            let point = element.hitPoint ?? element.frame?.centre
            let position = point.map { " hitPoint: (\(Int($0.x)),\(Int($0.y))) pts" } ?? ""
            let size = element.frame.map { " \(Int($0.width))x\(Int($0.height))" } ?? ""
            let identity = element.id.isEmpty && element.label.isEmpty
                ? "[unlabeled] \(element.type?.rawValue ?? "element")"
                : "[\(element.id.prefix(240))] \(element.label.prefix(240))"
            return identity + position + size
        }
        let next = page.offset + selected.count
        var fields: [String: Value] = [
            "elements": .array(rows), "total": .int(elements.count), "has_more": .bool(next < elements.count)
        ]
        if next < elements.count {
            fields["next_offset"] = .int(next)
        }
        return ToolResult(
            content: "Found \(elements.count) element(s):\n" + descriptions.joined(separator: "\n")
                + (next < elements.count ? "\nMore results: offset=\(next)" : ""),
            structuredContent: .object(fields),
            observedElements: selected.map { element in
                RecordedElement(
                    id: element.id.isEmpty ? nil : element.id,
                    label: element.label.isEmpty ? nil : element.label,
                    elementType: element.type?.rawValue,
                    frame: element.frame.map { RecordedRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                    hitPoint: element.hitPoint.map { RecordedPoint(x: $0.x, y: $0.y) }
                )
            }
        )
    }

    func elementFields(_ element: ElementInfo) -> Value {
        var fields: [String: Value] = [
            "id": .string(element.id), "label": .string(String(element.label.prefix(240))),
            "type": .string(element.type?.rawValue ?? "other"),
            "visible": .bool(element.isVisible), "enabled": .bool(element.isEnabled)
        ]
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
