import CoreGraphics

struct ViewNodeSnapshot {
    var id: String
    var label: String
    var value: String = ""
    var isSecureTextEntry: Bool = false
    var type: String
    var frame: CGRect
    var hitPoint: CGPoint
    var isEnabled: Bool
    var isVisible: Bool
    var children: [ViewNodeSnapshot]
    /// Text-input placeholder; `nil` for other controls.
    var placeholder: String?
    var isSelected: Bool?
}

extension ViewNodeSnapshot {
    /// The same tree with every node's frame and hit point moved by `delta`.
    func translated(by delta: CGVector) -> ViewNodeSnapshot {
        var copy = self
        copy.frame = frame.offsetBy(dx: delta.dx, dy: delta.dy)
        copy.hitPoint = CGPoint(x: hitPoint.x + delta.dx, y: hitPoint.y + delta.dy)
        copy.children = children.map { $0.translated(by: delta) }
        return copy
    }
}
