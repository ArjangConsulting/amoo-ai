import AmooCore
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
        let plan = #"{"compiler":"ai","compilerVersion":"1","toolOperations":["#
            + #"{"id":"operation-1","tool":"tap_element","arguments":{"label":"Sign in"}},"#
            + #"{"id":"operation-2","tool":"assert_visible","arguments":{"id":"home"}}]}"#
        let content = "I created a two-step plan.\n<amoo-plan>\(plan)</amoo-plan>"
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        let transport = try ChatTransport(response: #require(String(bytes: data, encoding: .utf8)))
        let service = LiveStudioChatService(transport: transport, environment: { $0 == "TEST_KEY" ? "secret" : nil })

        let result = try await service.send(request(kind: .openAI, variable: "TEST_KEY"))

        #expect(result.message == "I created a two-step plan.")
        #expect(result.proposedPlan?.toolOperations?.map(\.tool) == ["tap_element", "assert_visible"])
    }

    @Test("provider connectivity can be checked before chatting")
    func providerCheck() async throws {
        let transport = ChatTransport(response: #"{"data":[]}"#)
        let service = LiveStudioChatService(transport: transport, environment: { $0 == "TEST_KEY" ? "secret" : nil })

        let result = try await service.check(.init(
            id: "openai",
            name: "OpenAI",
            kind: .openAI,
            baseUrl: "https://api.openai.com",
            model: "model",
            apiKeyEnvironmentVariable: "TEST_KEY"
        ))

        #expect(result.message.contains("Connected to OpenAI"))
        #expect(await transport.authorization == "Bearer secret")
    }

    @Test("Anthropic chat uses its native request and response format")
    func anthropicRequest() async throws {
        let transport = ChatTransport(response: #"{"content":[{"text":"Anthropic reply"}]}"#)
        let service = LiveStudioChatService(
            transport: transport,
            environment: { $0 == "ANTHROPIC_KEY" ? "secret" : nil }
        )

        let result = try await service.send(request(kind: .anthropic, variable: "ANTHROPIC_KEY"))

        #expect(result.message == "Anthropic reply")
        #expect(await transport.apiKey == "secret")
        #expect(await transport.anthropicVersion == "2023-06-01")
        #expect(await transport.body?.contains("max_tokens") == true)
    }

    @Test("Ollama chat and connectivity do not require a secret")
    func ollamaRequests() async throws {
        let transport = ChatTransport(response: #"{"message":{"content":"Local reply"}}"#)
        let service = LiveStudioChatService(transport: transport, environment: { _ in nil })
        let provider = StudioProviderProfile(
            id: "ollama",
            name: "Ollama",
            kind: .ollama,
            baseUrl: "http://localhost:11434",
            model: "qwen",
            apiKeyEnvironmentVariable: ""
        )
        let input = StudioChatRequest(
            provider: provider,
            messages: [.init(id: "assistant-1", role: .assistant, content: "Earlier")],
            activeTest: request(kind: .ollama, variable: "").activeTest
        )

        let result = try await service.send(input)
        let check = try await service.check(provider)

        #expect(result.message == "Local reply")
        #expect(check.message.contains("localhost"))
        #expect(await transport.authorization == nil)
        #expect(await transport.requestCount == 2)
    }

    @Test("HTTP and malformed provider responses produce actionable errors")
    func responseErrors() async {
        let rejected = ChatTransport(response: "denied", statusCode: 401)
        let rejectedService = LiveStudioChatService(
            transport: rejected,
            environment: { $0 == "TEST_KEY" ? "secret" : nil }
        )
        await #expect(throws: StudioChatError.self) {
            try await rejectedService.send(request(kind: .custom, variable: "TEST_KEY"))
        }

        let malformed = ChatTransport(response: "{}")
        let malformedService = LiveStudioChatService(
            transport: malformed,
            environment: { $0 == "TEST_KEY" ? "secret" : nil }
        )
        await #expect(throws: StudioChatError.self) {
            try await malformedService.send(request(kind: .openAI, variable: "TEST_KEY"))
        }
    }

    @Test("unsafe and malformed AI plans stay plain chat messages")
    func rejectedPlans() async throws {
        let plan = #"{"compiler":"ai","compilerVersion":"1","toolOperations":["#
            + #"{"id":"1","tool":"delete_app","arguments":{}}]}"#
        let content = "Keep this as advice.\n<amoo-plan>\(plan)</amoo-plan>"
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content]]]
        ])
        let transport = try ChatTransport(response: #require(String(bytes: data, encoding: .utf8)))
        let service = LiveStudioChatService(
            transport: transport,
            environment: { $0 == "TEST_KEY" ? "secret" : nil }
        )

        let result = try await service.send(request(kind: .openAI, variable: "TEST_KEY"))

        #expect(result.proposedPlan == nil)
        #expect(result.message.contains("<amoo-plan>"))
    }

    @Test("invalid endpoints and provider checks surface configuration errors")
    func providerCheckErrors() async {
        let service = LiveStudioChatService(
            transport: ChatTransport(response: "{}"),
            environment: { _ in nil }
        )
        let invalid = StudioProviderProfile(
            id: "invalid",
            name: "Invalid",
            kind: .custom,
            baseUrl: "://",
            model: "model",
            apiKeyEnvironmentVariable: "KEY"
        )
        let missingKey = StudioProviderProfile(
            id: "custom",
            name: "Custom",
            kind: .custom,
            baseUrl: "https://example.com",
            model: "model",
            apiKeyEnvironmentVariable: ""
        )

        await #expect(throws: StudioChatError.self) { try await service.check(invalid) }
        await #expect(throws: StudioChatError.self) { try await service.check(missingKey) }
    }

    @Test("provider checks reject HTTP and non-HTTP responses")
    func providerCheckResponses() async {
        let profile = StudioProviderProfile(
            id: "ollama",
            name: "Ollama",
            kind: .ollama,
            baseUrl: "http://localhost:11434",
            model: "model",
            apiKeyEnvironmentVariable: ""
        )
        let rejected = LiveStudioChatService(
            transport: ChatTransport(response: "offline", statusCode: 503),
            environment: { _ in nil }
        )
        let nonHTTP = LiveStudioChatService(
            transport: NonHTTPChatTransport(),
            environment: { _ in nil }
        )

        await #expect(throws: StudioChatError.self) { try await rejected.check(profile) }
        await #expect(throws: StudioChatError.self) { try await nonHTTP.check(profile) }
    }

    @Test("chat send rejects invalid endpoints and non-HTTP responses")
    func chatTransportConfigurationErrors() async {
        let transport = ChatTransport(response: "{}")
        let service = LiveStudioChatService(transport: transport, environment: { _ in "secret" })
        let invalidRequest = StudioChatRequest(
            provider: .init(
                id: "invalid",
                name: "Invalid",
                kind: .custom,
                baseUrl: "://",
                model: "model",
                apiKeyEnvironmentVariable: "KEY"
            ),
            messages: [],
            activeTest: request(kind: .custom, variable: "KEY").activeTest
        )
        await #expect(throws: StudioChatError.self) { try await service.send(invalidRequest) }

        let nonHTTP = LiveStudioChatService(
            transport: NonHTTPChatTransport(),
            environment: { _ in "secret" }
        )
        await #expect(throws: StudioChatError.self) {
            try await nonHTTP.send(request(kind: .custom, variable: "KEY"))
        }
    }

    @Test("Anthropic connectivity uses required provider headers")
    func anthropicProviderCheck() async throws {
        let transport = ChatTransport(response: "{}")
        let service = LiveStudioChatService(transport: transport, environment: { _ in "secret" })
        let provider = StudioProviderProfile(
            id: "anthropic",
            name: "Anthropic",
            kind: .anthropic,
            baseUrl: "https://api.anthropic.com",
            model: "model",
            apiKeyEnvironmentVariable: "KEY"
        )

        _ = try await service.check(provider)

        #expect(await transport.apiKey == "secret")
        #expect(await transport.anthropicVersion == "2023-06-01")
    }

    private func request(kind: StudioProviderKind, variable: String) -> StudioChatRequest {
        StudioChatRequest(
            provider: .init(
                id: "provider",
                name: "Provider",
                kind: kind,
                baseUrl: "https://example.com/v1",
                model: "model",
                apiKeyEnvironmentVariable: variable
            ),
            messages: [.init(id: "user-1", role: .user, content: "Hello")],
            activeTest: .init(formatVersion: 1, name: "Test", description: "", platform: .android, steps: [])
        )
    }
}

private actor ChatTransport: StudioHTTPTransport {
    private let response: String
    private let statusCode: Int
    private(set) var authorization: String?
    private(set) var apiKey: String?
    private(set) var anthropicVersion: String?
    private(set) var requestCount = 0
    private(set) var body: String?

    init(response: String, statusCode: Int = 200) {
        self.response = response
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        authorization = request.value(forHTTPHeaderField: "Authorization")
        apiKey = request.value(forHTTPHeaderField: "x-api-key")
        anthropicVersion = request.value(forHTTPHeaderField: "anthropic-version")
        body = request.httpBody.flatMap { String(bytes: $0, encoding: .utf8) }
        return (
            Data(response.utf8),
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}

private struct NonHTTPChatTransport: StudioHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}
