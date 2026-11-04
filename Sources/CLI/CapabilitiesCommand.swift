import AmooCore
import Foundation
import MCP
import MCPServer

func runCapabilitiesCommand(_ arguments: [String], store: DeviceRuntimeStore = DeviceRuntimeStore()) -> CLIResult {
    do {
        var flags = EnvFlagReader(arguments)
        let tool = try flags.value("--tool")
        let command = try flags.value("--command")
        let rawPlatform = try flags.value("--platform")
        let runtimeID = try flags.value("--runtime-id")
        _ = flags.take("--json")
        try flags.finish()
        let runtime = runtimeID.flatMap { store.runtime(id: $0) }
        if let runtimeID, runtime == nil {
            throw DeviceAccessError.unknownRuntime(runtimeID)
        }
        let platform = rawPlatform.flatMap(Platform.init(rawValue:)) ?? runtime?.amooPlatform
        if let rawPlatform, Platform(rawValue: rawPlatform) == nil {
            throw EnvCommandParseError.usage("Invalid --platform. Example: amoo capabilities --platform ios")
        }
        var fields = try CapabilityDiscovery.query(tool: tool, platform: platform).objectValue ?? [:]
        if let command {
            guard command == "device" else {
                throw EnvCommandParseError.usage("Unknown command schema. Example: amoo capabilities --command device")
            }
            fields["command"] = .string(command)
            fields["cli_arguments"] = DeviceInvocationFlag.schema
        }
        if let runtime {
            fields["runtime"] = .object([
                "runtime_id": .string(runtime.id), "device_id": .string(runtime.deviceID),
                "platform": .string(runtime.platform.rawValue), "state": .string(runtime.state.rawValue),
                "state_source": .string("stored"),
                "port": runtime.port.map(Value.int) ?? .null,
                "app_id": runtime.appID.map(Value.string) ?? .null
            ])
        }
        return CLIResult(output: renderJSON(Value.object(fields)), exitCode: 0)
    } catch {
        return CLIResult(output: renderJSON(["code": "invalid_argument", "message": "\(error)"]), exitCode: 1)
    }
}
