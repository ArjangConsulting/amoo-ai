public struct ElementSelector: Sendable, Equatable {
    public var id: String?
    public var label: String?
    public var containsText: String?
    public var description: String?
    public var parentSelector: ParentSelector?

    public init(
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        description: String? = nil,
        parentSelector: ParentSelector? = nil
    ) {
        self.id = id
        self.label = label
        self.containsText = containsText
        self.description = description
        self.parentSelector = parentSelector
    }
}

public indirect enum ParentSelector: Sendable, Equatable {
    case selector(ElementSelector)
}
