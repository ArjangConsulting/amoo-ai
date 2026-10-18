import StudioProtocol

/// How a plan operation's `id` / `label` / `contains_text` (and optional `parent_id`, `index` /
/// `first`) become an XCUITest element query.
///
/// The selector fields are constraints and all of them apply, the way the live resolver and both
/// companions apply them: `id = X AND label contains Y` matches only an element that has both. The
/// query is built in the same order the live resolver works in: ancestor scope first, then every
/// constraint, then `first` / `index` among the survivors.
extension XCUITestEmitter {
    static func query(
        _ operation: StudioToolOperation,
        context: StudioTestContext? = nil,
        idKey: String = "id",
        labelKey: String = "label",
        containsTextKey: String = "contains_text"
    ) throws -> String {
        let pick = try elementPick(operation)
        let id = operation.arguments[idKey]
        let label = operation.arguments[labelKey]
        let contains = operation.arguments[containsTextKey]
        guard id != nil || label != nil || contains != nil else {
            throw TestCodeGeneratorError.missingArgument(
                tool: operation.tool, argument: "id, label, or contains_text"
            )
        }
        let scope = scopeQuery(operation, context: context)
        // A lone id keeps the subscript form: one XCUIElement that fails on duplicates, exactly as
        // the live resolver reports `ambiguous_selector`. Anything combined, scoped or picked is a
        // matching query that can be narrowed.
        if let id, label == nil, contains == nil, scope.isAny {
            let mapped = context?.selectorExpressions[id]
            if let pick {
                // A custom lookup template has an unknown shape, so it cannot be narrowed.
                if mapped != nil, context?.idLookupTemplate != nil {
                    throw TestCodeGeneratorError.invalidArgument(
                        tool: operation.tool, argument: "index/first", value: "not supported with idLookupTemplate"
                    )
                }
                return "\(scope.expression).matching(identifier: \(mapped ?? literal(id)))\(pick.suffix)"
            }
            if mapped != nil {
                return lookupByID(id, context: context, scope: scope.expression)
            }
            return "\(scope.expression)[\(literal(id))]"
        }
        var query = scope.expression
        if let id {
            query += ".matching(identifier: \(context?.selectorExpressions[id] ?? literal(id)))"
        }
        if let label {
            query += ".matching(NSPredicate(format: \"label == %@\", \(literal(label))))"
        }
        if let contains {
            query += ".matching(NSPredicate(format: \"label CONTAINS %@\", \(literal(contains))))"
        }
        // With no id the recording resolved to the first match, which the label forms always did.
        return query + (pick ?? .first).suffix
    }

    /// The query the constraints run against: every element, or the descendants of `parent_id`.
    private static func scopeQuery(
        _ operation: StudioToolOperation,
        context: StudioTestContext?
    ) -> (expression: String, isAny: Bool) {
        let any = "app.descendants(matching: .any)"
        guard let parent = operation.arguments["parent_id"], !parent.isEmpty else { return (any, true) }
        return ("\(lookupByID(parent, context: context, scope: any)).descendants(matching: .any)", false)
    }

    /// The single element with identifier `id`, through the context's lookup template when mapped.
    private static func lookupByID(_ id: String, context: StudioTestContext?, scope: String) -> String {
        guard let mapped = context?.selectorExpressions[id] else { return "\(scope)[\(literal(id))]" }
        let template = context?.idLookupTemplate ?? "\(scope)[{{id}}]"
        return template.replacingOccurrences(of: "{{id}}", with: mapped)
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
