import Foundation
import MobileTestingCore

public struct AISuggestedAction: Sendable, Equatable, Codable {
    public var priority: Int
    public var action: String
    public var reason: String

    public init(priority: Int, action: String, reason: String) {
        self.priority = priority
        self.action = action
        self.reason = reason
    }
}

public struct AISuggestionReport: Sendable, Equatable, Codable {
    public var screenIntent: String
    public var suggestedActions: [AISuggestedAction]
    public var confidence: String
    public var accessibilityIssues: [String]
    public var developerFeedback: [String]

    public init(
        screenIntent: String,
        suggestedActions: [AISuggestedAction],
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

public struct AISuggestionRequest: Sendable, Equatable {
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

/// Protocol for AI providers that can analyze screen content.
public protocol AIProvider: Sendable {
    /// Describe the current screen in natural language.
    func describeScreen(context: ScreenContext, hierarchy: ViewNode) async throws -> String

    /// Suggest possible actions based on the current screen state.
    func suggestActions(request: AISuggestionRequest) async throws -> AISuggestionReport

    /// Find an element by natural language description.
    func resolveDescription(_ description: String, elements: [ElementInfo]) async throws -> [ElementInfo]
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

/// AI provider that uses a local Ollama instance for inference.
public actor OllamaProvider: AIProvider {
    static let defaultRequestTimeout: TimeInterval = 600
    private let baseURL: String
    private let model: String
    private let requestTimeout: TimeInterval
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        baseURL: String = "http://localhost:11434",
        model: String = "llama3.2",
        requestTimeout: TimeInterval = 600
    ) {
        self.baseURL = baseURL
        self.model = model
        self.requestTimeout = requestTimeout
        transport = { request in
            try await URLSession.shared.data(for: request)
        }
    }

    init(
        baseURL: String = "http://localhost:11434",
        model: String = "llama3.2",
        requestTimeout: TimeInterval = OllamaProvider.defaultRequestTimeout,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.baseURL = baseURL
        self.model = model
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    public func describeScreen(context: ScreenContext, hierarchy: ViewNode) async throws -> String {
        let prompt = buildDescribePrompt(context: context, hierarchy: hierarchy)
        return try await generate(prompt: prompt)
    }

    public func suggestActions(request: AISuggestionRequest) async throws -> AISuggestionReport {
        let prompt = buildSuggestPrompt(request: request)
        let images = supportsVisionInput ? request.screenshot.map { [base64EncodedImage($0)] } ?? [] : []
        let response = try await generateStructuredJSON(
            prompt: prompt,
            format: suggestionReportSchema,
            images: images
        )

        let data = try suggestionReportData(from: response)
        let report = try JSONDecoder().decode(AISuggestionReport.self, from: data)
        return normalizedSuggestionReport(report, fallback: deterministicSuggestionReport(for: request))
    }

    public func resolveDescription(_ description: String, elements: [ElementInfo]) async throws -> [ElementInfo] {
        let prompt = buildResolvePrompt(description: description, elements: elements)
        let response = try await generate(prompt: prompt)

        // Parse element IDs from the response and match
        let mentionedIDs = Set(response.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return elements.filter { mentionedIDs.contains($0.id) || mentionedIDs.contains($0.label) }
    }

    // MARK: - Ollama API

    private func generate(prompt: String) async throws -> String {
        try await generate(prompt: prompt, images: [], format: nil)
    }

    private func generateStructuredJSON(prompt: String, format: [String: Any], images: [String]) async throws -> String {
        try await generate(prompt: prompt, images: images, format: format)
    }

    private var supportsVisionInput: Bool {
        let lowered = model.lowercased()
        return lowered.contains("vision") || lowered.contains("llava") || lowered.contains("bakllava")
    }

    private func generate(prompt: String, images: [String], format: [String: Any]?) async throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1
            ]
        ]
        if !images.isEmpty {
            body["images"] = images
        }
        if let format {
            body["format"] = format
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await transport(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String
        else {
            throw OllamaError.invalidJSON
        }

        return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Prompt Building

    private func buildDescribePrompt(context: ScreenContext, hierarchy: ViewNode) -> String {
        """
        You are analyzing a mobile app screen. Describe what the user sees in 2-3 sentences.

        Screen context: \(context.summary)
        Screen title: \(context.screenTitle ?? "unknown")
        Interactable elements: \(context.interactableCount)

        View hierarchy root: \(hierarchy.id)
        Top-level children: \(hierarchy.children.map { "\($0.type?.rawValue ?? "view")(\($0.label))" }
            .joined(separator: ", "))

        Describe the screen concisely:
        """
    }

    private func buildSuggestPrompt(context: ScreenContext, elements: [ElementInfo]) -> String {
        buildSuggestPrompt(request: AISuggestionRequest(
            context: context,
            hierarchy: ViewNode(id: "root"),
            allElements: elements,
            interactableElements: elements,
            diagnostics: [],
            developerFeedback: [],
            screenshot: nil
        ))
    }

    private func buildSuggestPrompt(request: AISuggestionRequest) -> String {
        let screenSummary = suggestionScreenSummary(for: request)
        let interactableList = summarizedElements(request.interactableElements, limit: 12)
        let contextList = summarizedElements(request.allElements, limit: 12)
        let diagnostics = request.diagnostics.isEmpty ? "- none" : request.diagnostics.map { "- \($0)" }.joined(separator: "\n")
        let developerFeedback = request.developerFeedback.isEmpty ? "- none" : request.developerFeedback.map { "- \($0)" }.joined(separator: "\n")
        let imageGuidance = request.screenshot == nil
            ? "No screenshot is attached, so rely on the accessibility tree only."
            : "A screenshot is attached. Use it for layout and intent, but use accessibility metadata as ground truth for naming targets."

        return """
        You are a senior mobile QA assistant. Analyze the current screen and return JSON that matches the requested schema.

        Prioritize the app's main user goal on this screen.
        Ignore OS/device chrome such as the status bar clock, Wi-Fi, signal, battery, carrier, home indicator, and other non-app UI.
        Do not enumerate every possible tap target.
        Prefer actions that advance the main flow, validate important behavior, or test likely failure paths.
        If the accessibility metadata is weak, lower confidence and explain which fixes would improve future AI guidance.
        \(imageGuidance)

        Screen context:
        \(screenSummary)

        Candidate interactable app elements:
        \(interactableList)

        Additional visible accessibility context:
        \(contextList)

        Accessibility issues already detected:
        \(diagnostics)

        Developer feedback candidates:
        \(developerFeedback)

        Return a JSON object with:
        - screenIntent: short screen purpose summary
        - suggestedActions: exactly 3 ranked actions with priority, action, and reason
        - confidence: one of high, medium, low
        - accessibilityIssues: concise list of issues limiting confidence
        - developerFeedback: concise list of concrete fixes developers should make
        """
    }

    private func buildResolvePrompt(description: String, elements: [ElementInfo]) -> String {
        let elementList = elements.prefix(30).map { el in
            "ID: \(el.id), Label: \(el.label), Type: \(el.type?.rawValue ?? "unknown")"
        }.joined(separator: "\n")

        return """
        Given the user's description: "\(description)"

        Which of these UI elements best matches? Return only the matching element ID(s).

        Elements:
        \(elementList)

        Matching IDs:
        """
    }

    private var suggestionReportSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "screenIntent": ["type": "string"],
                "suggestedActions": [
                    "type": "array",
                    "minItems": 3,
                    "maxItems": 3,
                    "items": [
                        "type": "object",
                        "properties": [
                            "priority": ["type": "integer"],
                            "action": ["type": "string"],
                            "reason": ["type": "string"]
                        ],
                        "required": ["priority", "action", "reason"]
                    ]
                ],
                "confidence": [
                    "type": "string",
                    "enum": ["high", "medium", "low"]
                ],
                "accessibilityIssues": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "developerFeedback": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ],
            "required": ["screenIntent", "suggestedActions", "confidence", "accessibilityIssues", "developerFeedback"]
        ]
    }

    private func suggestionScreenSummary(for request: AISuggestionRequest) -> String {
        let title = request.context.screenTitle?.isEmpty == false ? request.context.screenTitle! : "unknown"
        let root = request.hierarchy.id.isEmpty ? "unknown" : request.hierarchy.id
        return [
            "Summary: \(request.context.summary)",
            "Title: \(title)",
            "Root: \(root)",
            "Interactable count: \(request.interactableElements.count)",
            "Visible element count: \(request.allElements.count)"
        ].joined(separator: "\n")
    }

    private func summarizedElements(_ elements: [ElementInfo], limit: Int) -> String {
        let rows = elements.prefix(limit).map { element in
            let name = preferredElementName(label: element.label, id: element.id) ?? "unnamed"
            let type = element.type?.rawValue ?? "element"
            let valueSuffix = element.value.flatMap { $0.isEmpty ? nil : " value=\($0)" } ?? ""
            return "- \(type): \(name) (id: \(element.id))\(valueSuffix)"
        }
        return rows.isEmpty ? "- none" : rows.joined(separator: "\n")
    }

    private func base64EncodedImage(_ screenshot: ScreenshotData) -> String {
        Data(screenshot.bytes).base64EncodedString()
    }

    private func suggestionReportData(from response: String) throws -> Data {
        if let data = response.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else {
            throw OllamaError.invalidJSON
        }

        let slice = response[start ... end]
        guard let data = String(slice).data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw OllamaError.invalidJSON
        }

        return data
    }

    private func normalizedSuggestionReport(_ report: AISuggestionReport, fallback: AISuggestionReport) -> AISuggestionReport {
        let normalizedActions = Array(report.suggestedActions.prefix(3)).enumerated().map { index, action in
            AISuggestedAction(
                priority: index + 1,
                action: action.action.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: action.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.filter { !$0.action.isEmpty && !$0.reason.isEmpty }

        guard normalizedActions.count == 3 else {
            return fallback
        }

        let screenIntent = report.screenIntent.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = ["high", "medium", "low"].contains(report.confidence.lowercased()) ? report.confidence.lowercased() : fallback.confidence

        return AISuggestionReport(
            screenIntent: screenIntent.isEmpty ? fallback.screenIntent : screenIntent,
            suggestedActions: normalizedActions,
            confidence: confidence,
            accessibilityIssues: sanitizedLines(report.accessibilityIssues, fallback: fallback.accessibilityIssues),
            developerFeedback: sanitizedLines(report.developerFeedback, fallback: fallback.developerFeedback)
        )
    }

    private func sanitizedLines(_ values: [String], fallback: [String]) -> [String] {
        let lines = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? fallback : lines
    }
}

public enum OllamaError: Error, Sendable {
    case invalidBaseURL(String)
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case invalidJSON
    case notAvailable
}

/// AI provider that returns deterministic results without calling any external service.
/// Useful for testing and offline operation.
public struct LocalAIProvider: AIProvider {
    public init() {}

    public func describeScreen(context: ScreenContext, hierarchy: ViewNode) async throws -> String {
        formatScreenDescription(context: context, hierarchy: hierarchy, interactableElements: [])
    }

    public func suggestActions(request: AISuggestionRequest) async throws -> AISuggestionReport {
        deterministicSuggestionReport(for: request)
    }

    public func resolveDescription(_ description: String, elements: [ElementInfo]) async throws -> [ElementInfo] {
        let lowered = description.lowercased()
        return elements.filter {
            $0.label.lowercased().contains(lowered) || $0.id.lowercased().contains(lowered)
        }
    }
}

func deterministicSuggestionReport(for request: AISuggestionRequest) -> AISuggestionReport {
    let focusElements = request.interactableElements.isEmpty ? request.allElements : request.interactableElements
    let topElements = Array(focusElements.prefix(3))
    let actions = topElements.enumerated().map { index, element in
        AISuggestedAction(
            priority: index + 1,
            action: deterministicAction(for: element, fallbackIndex: index),
            reason: deterministicReason(for: element)
        )
    }

    let paddedActions = padSuggestedActions(actions, using: request)
    let confidence = request.diagnostics.isEmpty ? "medium" : "low"
    let screenIntent = inferScreenIntent(from: request)
    let accessibilityIssues = request.diagnostics.isEmpty ? ["No major accessibility issues detected from the current tree."] : request.diagnostics
    let feedback = request.developerFeedback.isEmpty ? ["Add clear, unique accessibility labels to primary actions and form fields to improve AI guidance."] : request.developerFeedback

    return AISuggestionReport(
        screenIntent: screenIntent,
        suggestedActions: paddedActions,
        confidence: confidence,
        accessibilityIssues: accessibilityIssues,
        developerFeedback: feedback
    )
}

private func padSuggestedActions(_ actions: [AISuggestedAction], using request: AISuggestionRequest) -> [AISuggestedAction] {
    var padded = actions

    if padded.isEmpty {
        padded.append(
            AISuggestedAction(
                priority: 1,
                action: "Review the current screen for missing primary actions",
                reason: "No reliable interactable app elements were exposed in the accessibility tree."
            )
        )
    }

    while padded.count < 3 {
        let priority = padded.count + 1
        let fallbackAction: AISuggestedAction
        switch priority {
        case 2:
            fallbackAction = AISuggestedAction(
                priority: priority,
                action: "Validate the main path with an alternate or invalid input",
                reason: "High-value flows should cover validation and error handling, not just the happy path."
            )
        default:
            fallbackAction = AISuggestedAction(
                priority: priority,
                action: "Improve accessibility labels for the visible controls",
                reason: request.developerFeedback.first ?? "Better labels and identifiers will make future suggestions more accurate."
            )
        }
        padded.append(fallbackAction)
    }

    return padded.enumerated().map { index, action in
        AISuggestedAction(priority: index + 1, action: action.action, reason: action.reason)
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

private func inferScreenIntent(from request: AISuggestionRequest) -> String {
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
