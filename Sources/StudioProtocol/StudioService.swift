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

public struct StudioService: Sendable {
    public static let protocolVersion = 1

    private let workspace: any StudioDeviceWorkspace

    public init(workspace: any StudioDeviceWorkspace = LiveStudioDeviceWorkspace()) {
        self.workspace = workspace
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

    public func handle(_ data: Data) async -> Data {
        do {
            let request = try JSONDecoder().decode(Request.self, from: data)
            let result: AnyJSON
            switch request.method {
            case "system.handshake":
                result = try encodeValue(StudioHandshake(
                    protocolVersion: Self.protocolVersion,
                    product: "amoo",
                    version: AmooVersion.current,
                    capabilities: ["health", "devices.list", "devices.start", "apps.buildInstallRun", "apps.reinstallRun", "apps.resetData"]
                ))
            case "system.health":
                result = try encodeValue(StudioHealth(status: "ready"))
            case "devices.list":
                result = try encodeValue(StudioDeviceList(devices: await workspace.listDevices()))
            case "devices.start":
                result = try encodeValue(await workspace.startDevice(try request.required("id")))
            case "apps.buildInstallRun":
                result = try encodeValue(await workspace.buildInstallRun(try request.appRequest()))
            case "apps.reinstallRun":
                result = try encodeValue(await workspace.reinstallRun(try request.appRequest()))
            case "apps.resetData":
                result = try encodeValue(await workspace.resetData(try request.appRequest()))
            default:
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
        StudioAppRequest(
            deviceId: try required("deviceId"), platform: optional("platform"),
            projectPath: optional("projectPath"), appId: try required("appId"),
            schemeOrModule: optional("schemeOrModule"), artifactPath: optional("artifactPath")
        )
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
