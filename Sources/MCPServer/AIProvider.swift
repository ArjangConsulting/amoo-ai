import Foundation
import MobileTestingCore

/// Protocol for AI providers that can analyze screen content.
public protocol AIProvider: Sendable {
    /// Describe the current screen in natural language.
    func describeScreen(context: ScreenContext, hierarchy: ViewNode) async throws -> String

    /// Suggest possible actions based on the current screen state.
    func suggestActions(context: ScreenContext, interactableElements: [ElementInfo]) async throws -> [String]

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

private func preferredElementName(label: String, id: String) -> String? {
    if !label.isEmpty {
        return label
    }

    if !id.isEmpty {
        return id
    }

    return nil
}

/// AI provider that uses a local Ollama instance for inference.
public actor OllamaProvider: AIProvider {
    private let baseURL: String
    private let model: String
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(baseURL: String = "http://localhost:11434", model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
        transport = { request in
            try await URLSession.shared.data(for: request)
        }
    }

    init(
        baseURL: String = "http://localhost:11434",
        model: String = "llama3.2",
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    public func describeScreen(context: ScreenContext, hierarchy: ViewNode) async throws -> String {
        let prompt = buildDescribePrompt(context: context, hierarchy: hierarchy)
        return try await generate(prompt: prompt)
    }

    public func suggestActions(context: ScreenContext, interactableElements: [ElementInfo]) async throws -> [String] {
        let prompt = buildSuggestPrompt(context: context, elements: interactableElements)
        let response = try await generate(prompt: prompt)
        return response.components(separatedBy: "\n").filter { !$0.isEmpty }
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
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw OllamaError.invalidBaseURL(baseURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
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
        let elementList = elements.prefix(20).map { el in
            "- \(el.type?.rawValue ?? "element"): \"\(el.label)\" (id: \(el.id))"
        }.joined(separator: "\n")

        return """
        You are a mobile test automation assistant. Given the current screen state, suggest 3-5 meaningful test actions.

        Screen: \(context.summary)
        Interactable elements:
        \(elementList)

        Suggest actions (one per line, be specific about which element to interact with):
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

    public func suggestActions(context _: ScreenContext, interactableElements: [ElementInfo]) async throws -> [String] {
        interactableElements.prefix(5).map { el in
            "Tap \(el.label.isEmpty ? el.id : el.label)"
        }
    }

    public func resolveDescription(_ description: String, elements: [ElementInfo]) async throws -> [ElementInfo] {
        let lowered = description.lowercased()
        return elements.filter {
            $0.label.lowercased().contains(lowered) || $0.id.lowercased().contains(lowered)
        }
    }
}
