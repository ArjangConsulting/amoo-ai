import AmooCore
import Foundation

public struct StudioHandshake: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let product: String
    public let version: String
    public let capabilities: [String]
}

public struct StudioHealth: Codable, Equatable, Sendable {
    public let status: String
}

public struct StudioMCPStatus: Codable, Equatable, Sendable {
    public let available: Bool
    public let transport: String
    public let arguments: [String]
}

public struct StudioService: Sendable {
    public static let protocolVersion = 1

    private let workspace: any StudioDeviceWorkspace
    private let chat: any StudioChatServing
    private let automation: any StudioAutomationServing

    public init(
        workspace: any StudioDeviceWorkspace = LiveStudioDeviceWorkspace(),
        chat: any StudioChatServing = LiveStudioChatService(),
        automation: (any StudioAutomationServing)? = nil
    ) {
        self.workspace = workspace
        self.chat = chat
        self.automation = automation ?? LiveStudioAutomationService(workspace: workspace)
    }

    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        while true {
            do {
                guard let request = try ContentLengthFraming.readMessage(from: input) else { return }
                let response = await handle(request)
                try ContentLengthFraming.writeMessage(response, to: output)
            } catch {
                return
            }
        }
    }

    /// Capabilities advertised in the handshake. Kept next to the routing functions below so a new
    /// method is hard to add without also advertising it.
    ///
    /// These are capability names, not method names, and the two deliberately differ in one place:
    /// the health *method* is `system.health` while the advertised *capability* is `health`. The
    /// Studio client keys off these strings, so aligning them would be a wire-breaking change, not
    /// a tidy-up.
    static let advertisedCapabilities = [
        "health",
        "devices.list",
        "devices.start",
        "devices.create",
        "apps.buildInstallRun",
        "apps.reinstallRun",
        "apps.resetData",
        "chat.send",
        "providers.check",
        "repl.execute",
        "tests.run",
        "tests.start",
        "tests.status",
        "tests.cancel",
        "tests.export",
        "reports.list",
        "mcp.status"
    ]

    public func handle(_ data: Data) async -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            guard let result = try await route(request) else {
                return encode(Response(
                    id: request.id,
                    error: .init(code: -32601, message: "Unknown method: \(request.method)")
                ))
            }
            return encode(Response(id: request.id, result: result))
        } catch {
            return encode(Response(id: nil, error: .init(code: -32700, message: "Invalid request: \(error)")))
        }
    }

    /// Returns `nil` when no family recognizes the method, which `handle` turns into -32601.
    /// Split by family so each switch stays small enough to read in one go.
    private func route(_ request: Request) async throws -> AnyJSON? {
        if let result = try systemResult(for: request) {
            return result
        }
        if let result = try await deviceResult(for: request) {
            return result
        }
        if let result = try await appResult(for: request) {
            return result
        }
        if let result = try await chatResult(for: request) {
            return result
        }
        return try await automationResult(for: request)
    }

    private func systemResult(for request: Request) throws -> AnyJSON? {
        switch request.method {
        case "system.handshake":
            try encodeValue(StudioHandshake(
                protocolVersion: Self.protocolVersion,
                product: "amoo",
                version: AmooVersion.current,
                capabilities: Self.advertisedCapabilities
            ))
        case "system.health":
            try encodeValue(StudioHealth(status: "ready"))
        case "mcp.status":
            try encodeValue(StudioMCPStatus(available: true, transport: "stdio", arguments: ["mcp", "serve"]))
        default:
            nil
        }
    }

    private func deviceResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "devices.list":
            try await encodeValue(StudioDeviceList(devices: workspace.listDevices()))
        case "devices.start":
            try await encodeValue(workspace.startDevice(request.required("id")))
        case "devices.create":
            try await encodeValue(workspace.createDevice(request.createDeviceRequest()))
        default:
            nil
        }
    }

    private func appResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "apps.buildInstallRun":
            try await encodeValue(workspace.buildInstallRun(request.appRequest()))
        case "apps.reinstallRun":
            try await encodeValue(workspace.reinstallRun(request.appRequest()))
        case "apps.resetData":
            try await encodeValue(workspace.resetData(request.appRequest()))
        default:
            nil
        }
    }

    private func chatResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "chat.send":
            try await encodeValue(chat.send(request.decodeParams(StudioChatRequest.self)))
        case "providers.check":
            try await encodeValue(chat.check(request.decodeParams(StudioProviderProfile.self)))
        default:
            nil
        }
    }

    private func automationResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "repl.execute":
            try await encodeValue(automation.execute(request.decodeParams(StudioReplRequest.self)))
        case "tests.run":
            try await encodeValue(automation.run(request.decodeParams(StudioTestRunRequest.self)))
        case "tests.start":
            try await encodeValue(automation.start(request.decodeParams(StudioTestRunRequest.self)))
        case "tests.status":
            try await encodeValue(automation.status(runId: request.required("runId")))
        case "tests.cancel":
            try await encodeValue(automation.cancel(runId: request.required("runId")))
        case "reports.list":
            try await encodeValue(automation.reports())
        case "tests.export":
            try await encodeValue(automation.export(request.decodeParams(StudioTestExportRequest.self)))
        default:
            nil
        }
    }

    private func encodeValue(_ value: some Encodable) throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value))
    }

    private func encode(_ response: Response) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
    }
}

private struct Request: Decodable {
    let id: AnyJSON?
    let method: String
    let params: [String: AnyJSON]?

    func required(_ key: String) throws -> String {
        guard case let .string(value)? = params?[key], !value.isEmpty else {
            throw StudioWorkspaceError.invalidParameter(key)
        }
        return value
    }

    func optional(_ key: String) -> String? {
        guard case let .string(value)? = params?[key], !value.isEmpty else { return nil }
        return value
    }

    func appRequest() throws -> StudioAppRequest {
        try StudioAppRequest(
            deviceId: required("deviceId"),
            platform: optional("platform"),
            projectPath: optional("projectPath"),
            appId: required("appId"),
            schemeOrModule: optional("schemeOrModule"),
            artifactPath: optional("artifactPath")
        )
    }

    func createDeviceRequest() throws -> StudioCreateDeviceRequest {
        let platformValue = try required("platform")
        guard let platform = StudioPlatform(rawValue: platformValue.capitalized) else {
            throw StudioWorkspaceError.invalidParameter("platform")
        }
        return try StudioCreateDeviceRequest(
            platform: platform,
            name: required("name"),
            runtime: required("runtime"),
            deviceType: required("deviceType")
        )
    }

    func decodeParams<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(params ?? [:]))
    }
}

private struct Response: Encodable {
    let jsonrpc = "2.0"
    let id: AnyJSON?
    let result: AnyJSON?
    let error: RPCError?

    init(id: AnyJSON?, result: AnyJSON) {
        self.id = id
        self.result = result
        error = nil
    }

    init(id: AnyJSON?, error: RPCError) {
        self.id = id
        result = nil
        self.error = error
    }
}

private struct RPCError: Codable {
    let code: Int
    let message: String
}

private enum AnyJSON: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}
