public struct ElementSelector: Sendable, Equatable {
    public var id: String?
    public var label: String?
    public var containsText: String?
    public var description: String?
    public var parentSelector: ParentSelector?

    /// Restricts results to elements carrying an identifier or a label.
    ///
    /// Off by default, so an unfiltered query also returns unlabeled elements — an icon-only
    /// close button with no accessibility label is reachable by its frame instead of being
    /// invisible to every query. Set it when only named elements are wanted, which is what a
    /// screen summary needs: it describes a screen by what its elements are called, and a
    /// frame-only entry contributes nothing to that.
    ///
    /// The accessibility reports leave it off deliberately. An element with neither identifier
    /// nor label is precisely the finding they exist to produce.
    ///
    /// No effect alongside `id`, `label`, or `containsText`: an unlabeled element cannot match
    /// any of those.
    public var labeledOnly: Bool

    public init(
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        description: String? = nil,
        parentSelector: ParentSelector? = nil,
        labeledOnly: Bool = false
    ) {
        self.id = id
        self.label = label
        self.containsText = containsText
        self.description = description
        self.parentSelector = parentSelector
        self.labeledOnly = labeledOnly
    }
}

indirect public enum ParentSelector: Sendable, Equatable {
    case selector(ElementSelector)
}
