import CoreGraphics

struct ViewNodeSnapshot {
    var id: String
    var label: String
    var type: String
    var frame: CGRect
    var isEnabled: Bool
    var isVisible: Bool
    var children: [ViewNodeSnapshot]
}
