import AmooCore

/// The selector contract shared by every tool that takes `id`, `label`, `contains_text` and
/// `parent_id`.
///
/// `id`, `label` and `contains_text` are **constraints**: when more than one is given the element
/// must satisfy all of them (the companions already match this way; the host used to pick one and
/// drop the rest, so `assert_visible(id: "day", contains_text: "Range end")` passed on the
/// identifier alone). `parent_id` scopes the search to that element's descendants before any
/// constraint is applied, and `index` / `first` pick among the survivors afterwards.
///
/// `description` and `field_description` are different in kind: a natural-language guess resolved
/// by fuzzy search, not a constraint. Combining one with an exact field has no honest meaning, so
/// it is rejected instead of silently ignored.
extension DriverToolExecutor {
    /// Builds the selector the arguments describe, or `nil` when none of them select anything.
    ///
    /// - Parameter includeDescription: whether `description` / `field_description` may select by
    ///   themselves when no exact constraint is present.
    /// - Throws: `invalid_argument` when a description is combined with an exact constraint.
    func preferredSelector(
        arguments: [String: String],
        includeDescription: Bool = false
    ) throws -> ElementSelector? {
        func value(_ key: String) -> String? {
            arguments[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        let id = value("id")
        let label = value("label")
        let text = value("contains_text")
        let description = value("field_description") ?? value("description")
        let parent = value("parent_id").map { ParentSelector.selector(ElementSelector(id: $0)) }

        if id != nil || label != nil || text != nil {
            if description != nil {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "description is a natural-language guess and cannot be combined with id, label,"
                        + " or contains_text. Pass the exact constraints, which must all match, or only the"
                        + " description."
                )
            }
            return ElementSelector(id: id, label: label, containsText: text, parentSelector: parent)
        }
        guard includeDescription, let description else { return nil }
        return ElementSelector(description: description, parentSelector: parent)
    }

    /// The exact constraints of `selector` as `id=…, label=…, contains_text=…`, for diagnostics.
    nonisolated static func describeConstraints(_ selector: ElementSelector) -> String {
        var parts: [String] = []
        if let id = selector.id {
            parts.append("id=\(id)")
        }
        if let label = selector.label {
            parts.append("label=\(label)")
        }
        if let text = selector.containsText {
            parts.append("contains_text=\(text)")
        }
        if let description = selector.description {
            parts.append("description=\(description)")
        }
        if case let .selector(parent) = selector.parentSelector, let parentID = parent.id {
            parts.append("parent_id=\(parentID)")
        }
        return parts.joined(separator: ", ")
    }
}
