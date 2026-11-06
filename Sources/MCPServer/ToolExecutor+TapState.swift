import AmooCore
import MCP

extension DriverToolExecutor {
    func observedTapState(_ target: ElementInfo, driver: any PlatformDriver) async -> Value {
        guard !target.id.isEmpty || !target.label.isEmpty else { return .null }
        let selector = ElementSelector(
            id: target.id.isEmpty ? nil : target.id,
            label: target.label.isEmpty ? nil : target.label
        )
        let elements = await Self.withinBudget(milliseconds: 1500) {
            try? await driver.findElements(selector)
        }
        guard let elements, elements.count == 1, let element = elements.first else { return .null }
        return .object([
            "selected": element.isSelected.map(Value.bool) ?? .null,
            "checked": element.semantics?.isChecked.map(Value.bool) ?? .null,
            "state_description": element.semantics?.stateDescription.map(Value.string) ?? .null,
            "value": element.value.map(Value.string) ?? .null,
            "proof": .string("observation; use an explicit assertion to complete required coverage")
        ])
    }
}
