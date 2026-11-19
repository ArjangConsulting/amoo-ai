/// What the platform hit test said about a tap on one element.
public enum HitTestVerdict: String, Sendable, Equatable {
    /// A tap at the element's hit point reaches the element or a descendant of it.
    case hittable
    /// Something else receives a tap at the element's hit point.
    case notHittable = "not_hittable"
    /// No single live element matched, so nothing was hit-tested.
    case unresolved
    /// The driver or companion cannot hit-test.
    case unsupported
}

public extension AccessibilityProvider {
    func hitTest(_: ElementInfo, appID _: String?) async throws -> HitTestVerdict {
        .unsupported
    }
}
