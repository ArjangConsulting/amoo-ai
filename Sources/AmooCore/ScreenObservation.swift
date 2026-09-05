// swiftlint:disable multiline_arguments
import Foundation

/// Context, elements, and change identity derived from one hierarchy RPC. The token includes
/// labels, values, geometry, visibility, enabled state, and tree order, within companion depth limits.
public struct ScreenObservation: Sendable {
    public let hierarchy: ViewNode
    public let elements: [ElementInfo]
    public let context: ScreenContext
    public let token: String
    public let capturedAt: Date

    public init(hierarchy: ViewNode, capturedAt: Date = Date()) {
        self.hierarchy = hierarchy
        self.capturedAt = capturedAt
        var nodes = [hierarchy]
        var elements: [ElementInfo] = []
        var hash: UInt64 = 14_695_981_039_346_656_037
        while let node = nodes.popLast() {
            let fields = [
                node.id,
                node.label,
                node.value ?? "",
                node.type?.rawValue ?? "",
                String(describing: node.frame),
                String(node.isVisible),
                String(node.isEnabled),
                String(node.children.count)
            ]
            for field in fields {
                for byte in "\(field.utf8.count):\(field)".utf8 {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                }
            }
            elements.append(ElementInfo(
                id: node.id, label: node.label, value: node.value, type: node.type, frame: node.frame,
                hitPoint: node.hitPoint, isEnabled: node.isEnabled, isVisible: node.isVisible,
                isSecureTextEntry: node.isSecureTextEntry
            ))
            nodes.append(contentsOf: node.children.reversed())
        }
        self.elements = elements
        token = String(hash, radix: 16)
        let visible = elements.filter(\.isVisible)
        let labels = visible.filter { !$0.label.isEmpty }.prefix(12).map { String($0.label.prefix(160)) }
        context = ScreenContext(
            summary: labels.isEmpty ? "Screen with \(visible.count) visible nodes" : labels.joined(separator: ", "),
            interactableCount: elements.filter(Self.isInteractable).count,
            screenTitle: labels.first
        )
    }

    public var interactableElements: [ElementInfo] {
        elements.filter(Self.isInteractable)
    }

    private static func isInteractable(_ element: ElementInfo) -> Bool {
        element.isVisible && element.isEnabled
            && [.button, .textField, .cell, .switchControl, .slider, .picker].contains(element.type)
    }
}

public extension AccessibilityProvider {
    /// One coherent observation, using the platform's scoped hierarchy request.
    func observeScreen(appID: String? = nil) async throws -> ScreenObservation {
        try await ScreenObservation(hierarchy: getViewHierarchy(appID: appID))
    }
}

public extension ElementType {
    init?(nativeName: String) {
        let normalized = nativeName.lowercased()
        if let exact = Self.allCases.first(where: { $0.rawValue.lowercased() == normalized }) {
            self = exact
        } else if normalized.contains("securetextfield") || normalized.contains("edittext") {
            self = .textField
        } else if normalized.contains("button") {
            self = .button
        } else if normalized.contains("textview") {
            self = .staticText
        } else if normalized.contains("webview") {
            self = .webView
        } else {
            return nil
        }
    }
}

// swiftlint:enable multiline_arguments
