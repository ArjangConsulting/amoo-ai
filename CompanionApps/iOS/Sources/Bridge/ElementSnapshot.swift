import CoreGraphics

struct ElementSnapshot {
    var id: String
    var label: String
    var value: String
    var type: String
    var frame: CGRect
    var hitPoint: CGPoint
    var isEnabled: Bool
    var isSecureTextEntry: Bool = false
    var isVisible: Bool
}
