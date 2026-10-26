import Foundation

/// Capture-scoped node identity, geometry, and raw provider properties. References expire with the capture.
public struct ElementSemantics: Sendable, Equatable, Codable {
    public var isCheckable: Bool?
    public var isChecked: Bool?
    public var stateDescription: String?
    public var reference: String
    public var parentReference: String
    public var hierarchyPath: String
    public var fullFrame: Rect?
    public var visibleFrame: Rect?
    public var attributes: [String: String]

    public init(
        reference: String = "",
        parentReference: String = "",
        hierarchyPath: String = "",
        fullFrame: Rect? = nil,
        visibleFrame: Rect? = nil,
        attributes: [String: String] = [:],
        isCheckable: Bool? = nil,
        isChecked: Bool? = nil,
        stateDescription: String? = nil
    ) {
        self.isCheckable = isCheckable
        self.isChecked = isChecked
        self.stateDescription = stateDescription
        self.reference = reference
        self.parentReference = parentReference
        self.hierarchyPath = hierarchyPath
        self.fullFrame = fullFrame
        self.visibleFrame = visibleFrame
        self.attributes = attributes
    }
}
