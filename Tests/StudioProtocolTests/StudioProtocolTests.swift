import Foundation
import StudioProtocol
import Testing

@Suite("Studio protocol")
struct StudioProtocolTests {
    @Test("handshake reports the protocol version and capabilities")
    func handshake() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake","params":{}}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["protocolVersion"] as? Int == StudioService.protocolVersion)
        #expect(result["product"] as? String == "amoo")
        #expect(result["capabilities"] as? [String] == [
            "health", "devices.list", "devices.start", "devices.create",
            "apps.buildInstallRun", "apps.reinstallRun", "apps.resetData", "chat.send", "providers.check",
            "repl.execute", "tests.run", "tests.start", "tests.status", "tests.cancel", "tests.export",
            "reports.list", "mcp.status"
        ])
    }

    @Test("unknown methods return JSON-RPC method-not-found")
    func methodNotFound() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":"abc","method":"missing"}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["code"] as? Int == -32601)
    }

    @Test("device list is returned as structured protocol data")
    func deviceList() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"devices.list","params":{}}"#.utf8)
        let response = await StudioService(workspace: StubWorkspace()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let devices = try #require(result["devices"] as? [[String: Any]])
        #expect(devices.first?["id"] as? String == "sim-1")
        #expect(devices.first?["status"] as? String == "Running")
    }

    @Test("device creation is routed through the typed workspace")
    func deviceCreation() async throws {
        let params = #"{"platform":"android","name":"Amoo Pixel","#
            + #""runtime":"system-images;android-36;google_apis;arm64-v8a","deviceType":"pixel_9"}"#
        let request = Data(
            (#"{"jsonrpc":"2.0","id":3,"method":"devices.create","params":"# + params + "}").utf8
        )
        let response = await StudioService(workspace: StubWorkspace()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["message"] as? String == "created Amoo Pixel")
    }

    @Test("chat requests are routed to the provider service")
    func chat() async throws {
        let provider = #"{"id":"ollama","name":"Local","kind":"Ollama","#
            + #""baseUrl":"http://localhost:11434","model":"qwen","apiKeyEnvironmentVariable":""}"#
        let messages = #"[{"id":"user-1","role":"User","content":"Explore"}]"#
        let activeTest = #"{"formatVersion":1,"name":"Test","description":"","#
            + #""platform":"Android","steps":[]}"#
        let params = #"{"provider":"# + provider
            + #","messages":"# + messages
            + #","activeTest":"# + activeTest + "}"
        let request = Data(
            (#"{"jsonrpc":"2.0","id":4,"method":"chat.send","params":"# + params + "}").utf8
        )
        let response = await StudioService(workspace: StubWorkspace(), chat: StubChat()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["message"] as? String == "Ready to explore")
    }

    @Test("MCP status reports the supported launch contract")
    func mcpStatus() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":5,"method":"mcp.status","params":{}}"#.utf8)
        let response = await StudioService(workspace: StubWorkspace(), chat: StubChat()).handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["available"] as? Bool == true)
        #expect(result["transport"] as? String == "stdio")
        #expect(result["arguments"] as? [String] == ["mcp", "serve"])
    }
}

private actor StubAutomation: StudioAutomationServing {
    func execute(_: StudioReplRequest) async throws -> StudioReplResult {
        .init(output: "executed")
    }

    func run(_: StudioTestRunRequest) async throws -> StudioTestRunResult {
        .init(
            message: "passed",
            sessionId: "session-1",
            reportId: "report-1"
        )
    }

    func reports() async -> StudioReportListResult {
        .init(reports: [])
    }

    func start(_: StudioTestRunRequest) -> StudioTestStartResult {
        .init(runId: "run-1")
    }

    func status(runId: String) -> StudioTestRunStatus {
        .init(
            runId: runId,
            state: .running,
            currentOperation: 0,
            totalOperations: 1,
            message: "running",
            sessionId: nil,
            reportId: nil
        )
    }

    func cancel(runId: String) -> StudioTestRunStatus {
        .init(
            runId: runId,
            state: .cancelled,
            currentOperation: 0,
            totalOperations: 1,
            message: "cancelled",
            sessionId: nil,
            reportId: nil
        )
    }
}

private struct StubChat: StudioChatServing {
    func send(_: StudioChatRequest) async throws -> StudioChatResult {
        StudioChatResult(message: "Ready to explore")
    }

    func check(_: StudioProviderProfile) async throws -> StudioProviderCheckResult {
        .init(message: "connected")
    }
}

private struct StubWorkspace: StudioDeviceWorkspace {
    func listDevices() async -> [StudioDevice] {
        [.init(
            id: "sim-1",
            name: "iPhone",
            platform: .ios,
            osVersion: "26.0",
            status: .running,
            physical: false
        )]
    }

    func startDevice(_: String) async -> StudioOperationResult {
        .init(message: "started", artifactPath: nil)
    }

    func createDevice(_ request: StudioCreateDeviceRequest) async -> StudioOperationResult {
        .init(
            message: "created \(request.name)",
            artifactPath: nil
        )
    }

    func buildInstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        .init(
            message: "built",
            artifactPath: "/tmp/App.app"
        )
    }

    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        .init(
            message: "installed",
            artifactPath: nil
        )
    }

    func resetData(_: StudioAppRequest) async -> StudioOperationResult {
        .init(message: "reset", artifactPath: nil)
    }
}
