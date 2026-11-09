import AmooCore
import MCP

extension DriverToolExecutor {
    /// The tapped element's state after the tap, as an observation (never a postcondition).
    ///
    /// Taken from `hierarchy`, the read the effect check already made, so no further snapshot is
    /// needed. Without one (no read succeeded) or when several nodes carry the target's id and
    /// label — a button and its text, say — the companion is asked to disambiguate.
    func observedTapState(
        _ target: ElementInfo,
        in hierarchy: ViewNode?,
        driver: any PlatformDriver
    ) async -> Value {
        guard !target.id.isEmpty || !target.label.isEmpty else { return .null }
        if let hierarchy {
            let matches = Self.nodes(named: target, in: hierarchy)
            switch matches.count {
            case 0:
                return .null
            case 1:
                return Self.tapState(
                    selected: matches[0].isSelected, semantics: matches[0].semantics, value: matches[0].value
                )
            default:
                break
            }
        }
        let selector = ElementSelector(
            id: target.id.isEmpty ? nil : target.id,
            label: target.label.isEmpty ? nil : target.label
        )
        let elements = await Self.withinBudget(milliseconds: 1500) {
            try? await driver.findElements(selector)
        }
        guard let elements, elements.count == 1, let element = elements.first else { return .null }
        return Self.tapState(selected: element.isSelected, semantics: element.semantics, value: element.value)
    }

    /// Every node whose id and label equal the target's, ignoring a part the target does not have.
    static func nodes(named target: ElementInfo, in root: ViewNode) -> [ViewNode] {
        var found: [ViewNode] = []
        func walk(_ node: ViewNode) {
            if target.id.isEmpty || node.id == target.id, target.label.isEmpty || node.label == target.label {
                found.append(node)
            }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func tapState(selected: Bool?, semantics: ElementSemantics?, value: String?) -> Value {
        .object([
            "selected": selected.map(Value.bool) ?? .null,
            "checked": semantics?.isChecked.map(Value.bool) ?? .null,
            "state_description": semantics?.stateDescription.map(Value.string) ?? .null,
            "value": value.map(Value.string) ?? .null,
            "proof": .string("observation; use an explicit assertion to complete required coverage")
        ])
    }
}
