import Foundation
import MobileTestingCore

public struct SuggestedTestAction: Sendable, Equatable, Codable {
    public var priority: Int
    public var action: String
    public var reason: String

    public init(priority: Int, action: String, reason: String) {
        self.priority = priority
        self.action = action
        self.reason = reason
    }
}

public struct TestActionSuggestionReport: Sendable, Equatable, Codable {
    public var screenIntent: String
    public var suggestedActions: [SuggestedTestAction]
    public var confidence: String
    public var accessibilityIssues: [String]
    public var developerFeedback: [String]

    public init(
        screenIntent: String,
        suggestedActions: [SuggestedTestAction],
        confidence: String,
        accessibilityIssues: [String],
        developerFeedback: [String]
    ) {
        self.screenIntent = screenIntent
        self.suggestedActions = suggestedActions
        self.confidence = confidence
        self.accessibilityIssues = accessibilityIssues
        self.developerFeedback = developerFeedback
    }
}

public struct TestActionSuggestionRequest: Sendable, Equatable {
    public var context: ScreenContext
    public var hierarchy: ViewNode
    public var allElements: [ElementInfo]
    public var interactableElements: [ElementInfo]
    public var diagnostics: [String]
    public var developerFeedback: [String]
    public var screenshot: ScreenshotData?

    public init(
        context: ScreenContext,
        hierarchy: ViewNode,
        allElements: [ElementInfo],
        interactableElements: [ElementInfo],
        diagnostics: [String],
        developerFeedback: [String],
        screenshot: ScreenshotData?
    ) {
        self.context = context
        self.hierarchy = hierarchy
        self.allElements = allElements
        self.interactableElements = interactableElements
        self.diagnostics = diagnostics
        self.developerFeedback = developerFeedback
        self.screenshot = screenshot
    }
}

public struct AITestabilityReport: Sendable, Equatable, Codable {
    public var screenSummary: String
    public var interactableCount: Int
    public var confidence: String
    public var diagnostics: [String]
    public var developerFeedback: [String]

    public init(
        screenSummary: String,
        interactableCount: Int,
        confidence: String,
        diagnostics: [String],
        developerFeedback: [String]
    ) {
        self.screenSummary = screenSummary
        self.interactableCount = interactableCount
        self.confidence = confidence
        self.diagnostics = diagnostics
        self.developerFeedback = developerFeedback
    }
}

public struct ElementMatch: Sendable, Equatable, Codable {
    public var id: String
    public var label: String
    public var type: String?

    public init(id: String, label: String, type: String?) {
        self.id = id
        self.label = label
        self.type = type
    }
}

public struct ElementDescriptionMatchReport: Sendable, Equatable, Codable {
    public var query: String
    public var matches: [ElementMatch]

    public init(query: String, matches: [ElementMatch]) {
        self.query = query
        self.matches = matches
    }
}

func formatScreenDescription(
    context: ScreenContext,
    hierarchy: ViewNode,
    interactableElements: [ElementInfo]
) -> String {
    let topLevelSummary = hierarchy.children
        .prefix(5)
        .compactMap(screenNodeSummary)
    let interactableSummary = interactableElements
        .prefix(7)
        .compactMap(interactableElementSummary)

    var lines: [String] = []
    lines.append(context.screenTitle.flatMap { $0.isEmpty ? nil : "Screen title: \($0)" } ?? "Screen summary: \(context.summary)")

    if context.screenTitle?.isEmpty != false, !context.summary.isEmpty {
        lines.append("Context: \(context.summary)")
    }

    lines.append("Interactable elements: \(interactableElements.count)")

    if !topLevelSummary.isEmpty {
        lines.append("Visible structure: \(topLevelSummary.joined(separator: ", "))")
    } else if !hierarchy.label.isEmpty || hierarchy.type != nil {
        let rootDescription = screenNodeSummary(hierarchy) ?? hierarchy.id
        lines.append("Visible structure: \(rootDescription)")
    }

    if !interactableSummary.isEmpty {
        lines.append("Key actions: \(interactableSummary.joined(separator: "; "))")
    }

    return lines.joined(separator: "\n")
}

private func screenNodeSummary(_ node: ViewNode) -> String? {
    let name = preferredElementName(label: node.label, id: node.id)
    let type = node.type?.rawValue ?? "view"

    if let name, !name.isEmpty {
        return "\(type)(\(name))"
    }

    guard !node.id.isEmpty else { return nil }
    return "\(type)(id=\(node.id))"
}

private func interactableElementSummary(_ element: ElementInfo) -> String? {
    let name = preferredElementName(label: element.label, id: element.id)
    let type = element.type?.rawValue ?? "element"

    if let name, !name.isEmpty {
        return "\(type) \(name)"
    }

    guard !element.id.isEmpty else { return nil }
    return "\(type) id=\(element.id)"
}

func preferredElementName(label: String, id: String?) -> String? {
    if !label.isEmpty {
        return label
    }

    if let id, !id.isEmpty {
        return id
    }

    return nil
}

func deterministicSuggestionReport(for request: TestActionSuggestionRequest) -> TestActionSuggestionReport {
    let focusElements = request.interactableElements.isEmpty ? request.allElements : request.interactableElements
    let topElements = Array(focusElements.prefix(3))
    let actions = topElements.enumerated().map { index, element in
        SuggestedTestAction(
            priority: index + 1,
            action: deterministicAction(for: element, fallbackIndex: index),
            reason: deterministicReason(for: element)
        )
    }

    let paddedActions = padSuggestedActions(actions, using: request)
    let confidence = testabilityConfidence(diagnostics: request.diagnostics, interactableCount: request.interactableElements.count)
    let screenIntent = inferScreenIntent(from: request)
    let accessibilityIssues = request.diagnostics.isEmpty ? ["No major accessibility issues detected from the current tree."] : request.diagnostics
    let feedback = request.developerFeedback.isEmpty ? ["Add clear, unique accessibility labels to primary actions and form fields to improve AI guidance."] : request.developerFeedback

    return TestActionSuggestionReport(
        screenIntent: screenIntent,
        suggestedActions: paddedActions,
        confidence: confidence,
        accessibilityIssues: accessibilityIssues,
        developerFeedback: feedback
    )
}

func testabilityConfidence(diagnostics: [String], interactableCount: Int) -> String {
    if interactableCount == 0 || diagnostics.count >= 3 {
        return "low"
    }
    if diagnostics.isEmpty {
        return "medium"
    }
    return "low"
}

private func padSuggestedActions(_ actions: [SuggestedTestAction], using request: TestActionSuggestionRequest) -> [SuggestedTestAction] {
    var padded = actions

    if padded.isEmpty {
        padded.append(
            SuggestedTestAction(
                priority: 1,
                action: "Review the current screen for missing primary actions",
                reason: "No reliable interactable app elements were exposed in the accessibility tree."
            )
        )
    }

    while padded.count < 3 {
        let priority = padded.count + 1
        let fallbackAction: SuggestedTestAction
        switch priority {
        case 2:
            fallbackAction = SuggestedTestAction(
                priority: priority,
                action: "Validate the main path with an alternate or invalid input",
                reason: "High-value flows should cover validation and error handling, not just the happy path."
            )
        default:
            fallbackAction = SuggestedTestAction(
                priority: priority,
                action: "Improve accessibility labels for the visible controls",
                reason: request.developerFeedback.first ?? "Better labels and identifiers will make future suggestions more accurate."
            )
        }
        padded.append(fallbackAction)
    }

    return padded.enumerated().map { index, action in
        SuggestedTestAction(priority: index + 1, action: action.action, reason: action.reason)
    }
}

private func deterministicAction(for element: ElementInfo, fallbackIndex: Int) -> String {
    let name = preferredElementName(label: element.label, id: element.id) ?? "the visible control"

    switch element.type {
    case .textField:
        return "Enter realistic and invalid values in \(name) to verify validation and form behavior"
    case .button:
        return "Tap \(name) and verify it advances the main flow or shows the correct state"
    case .cell, .table, .collectionView:
        return "Open \(name) to verify navigation and content details"
    case .switchControl, .slider, .picker:
        return "Change \(name) and verify the setting persists and updates the UI correctly"
    default:
        return fallbackIndex == 0
            ? "Interact with \(name) to verify the primary journey on this screen"
            : "Use \(name) to test an important alternate path on this screen"
    }
}

private func deterministicReason(for element: ElementInfo) -> String {
    switch element.type {
    case .textField:
        return "Form fields usually gate the main task and are a common source of validation regressions."
    case .button:
        return "Primary buttons often control the critical user flow and should be exercised first."
    case .cell, .table, .collectionView:
        return "Lists and cells usually represent navigation entry points or important content transitions."
    case .switchControl, .slider, .picker:
        return "Stateful controls should be tested for value changes, persistence, and side effects."
    default:
        return "This control is currently exposed as interactable and likely contributes to the visible task flow."
    }
}

private func inferScreenIntent(from request: TestActionSuggestionRequest) -> String {
    if let title = request.context.screenTitle, !title.isEmpty {
        return "Screen centered on \(title)."
    }

    let labels = request.allElements.prefix(8).compactMap { element -> String? in
        let value = preferredElementName(label: element.label, id: element.id)
        return value?.isEmpty == false ? value : nil
    }

    if !labels.isEmpty {
        return "Screen appears focused on \(labels.joined(separator: ", "))."
    }

    return request.context.summary.isEmpty ? "Screen intent is unclear from the current accessibility tree." : request.context.summary
}
