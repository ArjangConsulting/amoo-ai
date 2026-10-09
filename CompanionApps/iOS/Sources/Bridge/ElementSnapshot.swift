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
