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
        } else if let fromRawValue = Self(xcuiElementTypeDescription: normalized) {
            self = fromRawValue
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

    /// XCTest `XCUIElementType` raw values, grouped onto the host's element types.
    private static let xcuiRawValueTypes: [Int: Self] = {
        let groups: [(Self, [Int])] = [
            // button, radioButton, checkBox, popUpButton, menuButton, toolbarButton, key, link, menuItem, tab
            (.button, [9, 10, 12, 14, 16, 17, 20, 42, 54, 80]),
            // searchField, textField, secureTextField, textView
            (.textField, [45, 49, 50, 52]),
            (.staticText, [48]),
            // image, icon
            (.image, [43, 44]),
            (.cell, [75]),
            (.scrollView, [46]),
            (.table, [26]),
            (.collectionView, [32]),
            (.navigationBar, [21]),
            (.tabBar, [22]),
            // switch, toggle
            (.switchControl, [40, 41]),
            (.slider, [33]),
            // segmentedControl, picker, pickerWheel, datePicker
            (.picker, [37, 38, 39, 51]),
            (.alert, [7]),
            (.sheet, [5]),
            (.webView, [58]),
            (.other, [1])
        ]
        return Dictionary(uniqueKeysWithValues: groups.flatMap { type, raws in raws.map { ($0, type) } })
    }()

    /// Maps the `XCUIElementType(rawValue: N)` text an iOS companion produces when it
    /// string-interpolates `XCUIElement.ElementType`. Imported Objective-C enums carry no Swift case
    /// names, so that interpolation never yields `button`, and every element classified as `other`:
    /// `describe_screen` reported no interactable elements on any screen. Companions now send
    /// explicit names; this keeps ones built before that change classifying correctly.
    ///
    /// Raw values are XCTest's `XCUIElementType` ABI, stable across SDK releases.
    private init?(xcuiElementTypeDescription description: String) {
        let prefix = "xcuielementtype(rawvalue:"
        guard description.hasPrefix(prefix), description.hasSuffix(")"),
              let raw = Int(description.dropFirst(prefix.count).dropLast().trimmingCharacters(in: .whitespaces))
        else { return nil }
        guard let type = Self.xcuiRawValueTypes[raw] else { return nil }
        self = type
    }
}

// swiftlint:enable multiline_arguments
