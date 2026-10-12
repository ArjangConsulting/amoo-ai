import StudioProtocol

/// How a plan operation's `id` / `label` / `contains_text` (and optional `index` / `first`) become an
/// XCUITest element query.
extension XCUITestEmitter {
    static func query(
        _ operation: StudioToolOperation,
        context: StudioTestContext? = nil,
        idKey: String = "id",
        labelKey: String = "label",
        containsTextKey: String = "contains_text"
    ) throws -> String {
        let pick = try elementPick(operation)
        let any = "app.descendants(matching: .any)"
        if let id = operation.arguments[idKey] {
            let mapped = context?.selectorExpressions[id]
            if let pick {
                // A subscript lookup is one XCUIElement and fails on duplicates; a matching query
                // can be narrowed. A custom lookup template has an unknown shape, so it cannot be.
                if mapped != nil, context?.idLookupTemplate != nil {
                    throw TestCodeGeneratorError.invalidArgument(
                        tool: operation.tool, argument: "index/first", value: "not supported with idLookupTemplate"
                    )
                }
                return "\(any).matching(identifier: \(mapped ?? literal(id)))\(pick.suffix)"
            }
            if let mapped {
                let template = context?.idLookupTemplate ?? "\(any)[{{id}}]"
                return template.replacingOccurrences(of: "{{id}}", with: mapped)
            }
            return "\(any)[\(literal(id))]"
        }
        // A text selector already resolves to a single element through `.firstMatch`; a pick only
        // changes which match that is.
        if let label = operation.arguments[labelKey] {
            return "\(any).matching(NSPredicate(format: \"label == %@\", \(literal(label))))"
                + (pick ?? .first).suffix
        }
        if let contains = operation.arguments[containsTextKey] {
            return "\(any).matching(NSPredicate(format: \"label CONTAINS %@\", \(literal(contains))))"
                + (pick ?? .first).suffix
        }
        throw TestCodeGeneratorError.missingArgument(
            tool: operation.tool, argument: "id, label, or contains_text"
        )
    }

    /// Which of several matching elements the recording chose with `index` / `first`.
    enum ElementPick {
        case first
        case index(Int)

        /// The 0-based position among the matches, for emitters that index a list of them.
        var position: Int {
            switch self {
            case .first: 0
            case let .index(index): index
            }
        }

        /// The query suffix that narrows a multi-match query to one element.
        var suffix: String {
            switch self {
            case .first: ".firstMatch"
            case let .index(index): ".element(boundBy: \(index))"
            }
        }
    }

    static func elementPick(_ operation: StudioToolOperation) throws -> ElementPick? {
        if let raw = operation.arguments["index"] {
            guard let index = Int(raw), index >= 0 else {
                throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: "index", value: raw)
            }
            return .index(index)
        }
        if operation.arguments["first"]?.lowercased() == "true" {
            return .first
        }
        return nil
    }
}
