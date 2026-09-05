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
}
