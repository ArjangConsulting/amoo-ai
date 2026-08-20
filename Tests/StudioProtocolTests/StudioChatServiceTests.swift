import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StudioProtocol
import Testing

struct StudioChatServiceTests {
    @Test("OpenAI-compatible requests use environment credentials")
    func openAIRequest() async throws {
        let transport = ChatTransport(response: #"{"choices":[{"message":{"content":"Hello"}}]}"#)
        let service = LiveStudioChatService(transport: transport, environment: { $0 == "TEST_KEY" ? "secret" : nil })
        let result = try await service.send(request(kind: .openAI, variable: "TEST_KEY"))

        #expect(result.message == "Hello")
        #expect(await transport.authorization == "Bearer secret")
        #expect(await transport.body?.contains("active Amoo test") == true)
        #expect(await transport.body?.contains("Test") == true)
    }

    @Test("provider keys are required without performing a request")
    func missingKey() async {
        let transport = ChatTransport(response: "{}")
        let service = LiveStudioChatService(transport: transport, environment: { _ in nil })

        do {
            _ = try await service.send(request(kind: .anthropic, variable: "MISSING_KEY"))
            Issue.record("Expected the missing secret to fail.")
        } catch let error as StudioChatError {
            #expect(error.description.contains("MISSING_KEY"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.requestCount == 0)
    }

    @Test("AI plans are extracted for explicit Studio review")
    func proposedPlan() async throws {
        let content = """
        I created a two-step plan.
        <amoo-plan>{"compiler":"ai","compilerVersion":"1","toolOperations":[{"id":"operation-1","tool":"tap_element","arguments":{"label":"Sign in"}},{"id":"operation-2","tool":"assert_visible","arguments":{"id":"home"}}]}</amoo-plan>
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        let transport = ChatTransport(response: String(decoding: data, as: UTF8.self))
        let service = LiveStudioChatService(transport: transport, environment: { $0 == "TEST_KEY" ? "secret" : nil })

        let result = try await service.send(request(kind: .openAI, variable: "TEST_KEY"))

        #expect(result.message == "I created a two-step plan.")
        #expect(result.proposedPlan?.toolOperations?.map(\.tool) == ["tap_element", "assert_visible"])
    }

    @Test("provider connectivity can be checked before chatting")
    func providerCheck() async throws {
        let transport = ChatTransport(response: #"{"data":[]}"#)
        let service = LiveStudioChatService(transport: transport, environment: { $0 == "TEST_KEY" ? "secret" : nil })

        let result = try await service.check(.init(id: "openai", name: "OpenAI", kind: .openAI, baseUrl: "https://api.openai.com", model: "model", apiKeyEnvironmentVariable: "TEST_KEY"))

        #expect(result.message.contains("Connected to OpenAI"))
        #expect(await transport.authorization == "Bearer secret")
    }

    private func request(kind: StudioProviderKind, variable: String) -> StudioChatRequest {
        StudioChatRequest(
            provider: .init(id: "provider", name: "Provider", kind: kind, baseUrl: "https://example.com/v1", model: "model", apiKeyEnvironmentVariable: variable),
            messages: [.init(id: "user-1", role: .user, content: "Hello")],
            activeTest: .init(formatVersion: 1, name: "Test", description: "", platform: "Android", steps: [])
        )
    }
}

private actor ChatTransport: StudioHTTPTransport {
    private let response: String
    private(set) var authorization: String?
    private(set) var requestCount = 0
    private(set) var body: String?

    init(response: String) { self.response = response }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        authorization = request.value(forHTTPHeaderField: "Authorization")
        body = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
