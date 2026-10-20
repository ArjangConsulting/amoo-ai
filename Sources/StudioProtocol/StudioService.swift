import AmooCore
import AmooLogging
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

    /// Services post through this center; `run` connects it to the Studio transport.
    public let notifications: StudioNotificationCenter

    private let workspace: any StudioDeviceWorkspace
    private let chat: any StudioChatServing
    private let automation: any StudioAutomationServing
    private let deviceLocks: StudioDeviceLocks
    private let logger = AmooLogger.forType(Self.self)

    /// Pass the same `notifications` and `deviceLocks` to an injected `automation` so its pushed
    /// progress reaches this transport and its device work is ordered with this service's.
    public init(
        workspace: any StudioDeviceWorkspace = LiveStudioDeviceWorkspace(),
        chat: any StudioChatServing = LiveStudioChatService(),
        automation: (any StudioAutomationServing)? = nil,
        notifications: StudioNotificationCenter = .init(),
        deviceLocks: StudioDeviceLocks = .init()
    ) {
        self.workspace = workspace
        self.chat = chat
        self.notifications = notifications
        self.deviceLocks = deviceLocks
        self.automation = automation ?? LiveStudioAutomationService(
            workspace: workspace,
            notifications: notifications,
            deviceLocks: deviceLocks
        )
    }

    /// Serves framed JSON-RPC until `input` ends. Requests are handled concurrently, so a status
    /// poll or a cancellation is never stuck behind a long build or test run; `StudioDeviceLocks`
    /// keeps work on one device in order. Waits for in-flight requests before returning.
    public func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        let writer = StudioFrameWriter(output: output)
        let logger = logger
        await notifications.attach { body in
            do {
                try await writer.write(body)
            } catch {
                logger.error("Could not write notification", error: error)
            }
        }
        logger.info("Studio protocol serving")
        await withTaskGroup(of: Void.self) { group in
            for await message in ContentLengthFraming.frames(from: input) {
                group.addTask {
                    guard let response = await respond(to: message) else { return }
                    do {
                        try await writer.write(response)
                    } catch {
                        logger.error("Could not write response", error: error)
                    }
                }
            }
        }
        await notifications.detach()
        logger.info("Studio protocol input closed")
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
        "providers.apiKey",
        "repl.execute",
        "tests.run",
        "tests.start",
        "tests.status",
        "tests.cancel",
        "tests.export",
        "reports.list",
        "mcp.status",
        "rpc.concurrent",
        "rpc.notifications",
        "tests.progress"
    ]

    /// Handles one request and returns its response. A notification (no `id`) is still executed,
    /// but its response is encoded only for callers such as tests; `run` drops it.
    public func handle(_ data: Data) async -> Data {
        await response(to: data).body
    }

    private func respond(to data: Data) async -> Data? {
        let response = await response(to: data)
        return response.isNotification ? nil : response.body
    }

    private func response(to data: Data) async -> (body: Data, isNotification: Bool) {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return (encode(Response(id: nil, error: .init(code: -32700, message: "Parse error"))), false)
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: data)
        } catch {
            let id = try? JSONDecoder().decode(RequestID.self, from: data).id
            return (encode(Response(id: id, error: .init(code: -32600, message: "Invalid request: \(error)"))), false)
        }
        let isNotification = request.id == nil
        do {
            guard let result = try await route(request) else {
                return (encode(Response(
                    id: request.id,
                    error: .init(code: -32601, message: "Unknown method: \(request.method)")
                )), isNotification)
            }
            return (encode(Response(id: request.id, result: result)), isNotification)
        } catch {
            logger.error("Studio request failed", error: error, context: "method=\(request.method)")
            return (encode(Response(id: request.id, error: Self.rpcError(for: error))), isNotification)
        }
    }

    /// Bad parameters are the caller's fault (-32602); anything else is an internal error (-32603).
    /// The message is shown to the Studio user, so it stays the error's own description.
    private static func rpcError(for error: any Error) -> RPCError {
        switch error {
        case is DecodingError, StudioWorkspaceError.invalidParameter:
            .init(code: -32602, message: "Invalid params: \(error)")
        default:
            .init(code: -32603, message: String(describing: error))
        }
    }

    /// Returns `nil` when no family recognizes the method, which `handle` turns into -32601.
    /// Split by family so each switch stays small enough to read in one go.
    private func route(_ request: Request) async throws -> AnyJSON? {
        if let result = try await systemResult(for: request) {
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

    /// Capabilities that depend on how `amoo studio serve` was assembled, such as the tool catalog.
    static let catalogCapabilities = ["tools.catalog", "repl.complete", "repl.validate", "repl.structuredResults"]

    private func capabilities() async -> [String] {
        await automation.toolCatalog() == nil ? Self.advertisedCapabilities : Self.advertisedCapabilities + Self
            .catalogCapabilities
    }

    private func systemResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "system.handshake":
            try await encodeValue(StudioHandshake(
                protocolVersion: Self.protocolVersion,
                product: "amoo",
                version: AmooVersion.current,
                capabilities: capabilities()
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
            try await withDevice(request.required("id")) { [workspace] id in
                try await Self.encodeValue(workspace.startDevice(id))
            }
        case "devices.create":
            try await encodeValue(workspace.createDevice(request.createDeviceRequest()))
        default:
            nil
        }
    }

    private func appResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "apps.buildInstallRun":
            try await withApp(request) { [workspace] app in try await workspace.buildInstallRun(app) }
        case "apps.reinstallRun":
            try await withApp(request) { [workspace] app in try await workspace.reinstallRun(app) }
        case "apps.resetData":
            try await withApp(request) { [workspace] app in try await workspace.resetData(app) }
        default:
            nil
        }
    }

    private func catalogResult() async throws -> AnyJSON {
        guard let catalog = await automation.toolCatalog() else {
            throw StudioAutomationError.unsupportedCommand("tools.catalog")
        }
        return try encodeValue(catalog)
    }

    private func withDevice(
        _ deviceId: String,
        _ operation: @Sendable (String) async throws -> AnyJSON
    ) async throws -> AnyJSON {
        try await deviceLocks.withDevice(deviceId) { try await operation(deviceId) }
    }

    private func withApp(
        _ request: Request,
        _ operation: @Sendable (StudioAppRequest) async throws -> some Encodable & Sendable
    ) async throws -> AnyJSON {
        let app = try request.appRequest()
        let result = try await deviceLocks.withDevice(app.deviceId) { try await operation(app) }
        return try encodeValue(result)
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

    // A flat method dispatch; splitting it would only scatter the routing table.
    // swiftlint:disable:next cyclomatic_complexity
    private func automationResult(for request: Request) async throws -> AnyJSON? {
        switch request.method {
        case "repl.execute":
            try await encodeValue(automation.execute(request.decodeParams(StudioReplRequest.self)))
        case "repl.complete":
            try await encodeValue(automation.complete(request.decodeParams(StudioReplCompletionRequest.self)))
        case "repl.validate":
            try await encodeValue(automation.validate(request.decodeParams(StudioReplValidationRequest.self)))
        case "tools.catalog":
            try await catalogResult()
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
        try Self.encodeValue(value)
    }

    private static func encodeValue(_ value: some Encodable) throws -> AnyJSON {
        try JSONDecoder().decode(AnyJSON.self, from: JSONEncoder().encode(value))
    }

    private func encode(_ response: Response) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
    }
}

/// Recovers the `id` of a structurally invalid request so its error can still be correlated.
private struct RequestID: Decodable {
    let id: AnyJSON?
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

private struct RPCError: Codable, Sendable {
    let code: Int
    let message: String
}

private enum AnyJSON: Codable, Sendable {
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
