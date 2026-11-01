import CoreGraphics

struct ElementSnapshot {
    var isSelected: Bool?
    var id: String
    var label: String
    var value: String
    var type: String
    var frame: CGRect
    var hitPoint: CGPoint
    var isEnabled: Bool
    var isSecureTextEntry: Bool = false
    var isVisible: Bool
    /// Text-input placeholder; `nil` for other controls.
    var placeholder: String?
}

extension ElementSnapshot {
    /// The same element with its frame and hit point moved by `delta`.
    func translated(by delta: CGVector) -> ElementSnapshot {
        var copy = self
        copy.frame = frame.offsetBy(dx: delta.dx, dy: delta.dy)
        copy.hitPoint = CGPoint(x: hitPoint.x + delta.dx, y: hitPoint.y + delta.dy)
        return copy
    }
}
