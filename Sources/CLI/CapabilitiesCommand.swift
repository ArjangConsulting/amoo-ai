import AmooCore
import AmooTools
import Foundation

func renderCapabilitiesHelp() -> String {
    """
    Usage: amoo capabilities [--tool <name>] [--command device] [--platform ios|android|macos]
                             [--runtime-id <id>] [--json]

    Print installed tool schemas, assertion support and runtime identity as JSON, without a device.

      --tool <name>         One tool's argument and result schema
      --command device      The `amoo device` invocation flags
      --platform <p>        Assertion support on ios, android or macos
      --runtime-id <id>     Include a leased runtime's identity (from `amoo env up`)
      --json                Accepted for symmetry; output is always JSON

    Example:
      amoo capabilities --tool record_video --platform ios
    """
}

func runCapabilitiesCommand(_ arguments: [String], store: DeviceRuntimeStore = DeviceRuntimeStore()) -> CLIResult {
    if arguments.first == "help" || arguments.contains("--help") || arguments.contains("-h") {
        return CLIResult(output: renderCapabilitiesHelp(), exitCode: 0)
    }
    do {
        var flags = EnvFlagReader(arguments)
        let tool = try flags.value("--tool")
        let command = try flags.value("--command")
        let rawPlatform = try flags.value("--platform")
        let runtimeID = try flags.value("--runtime-id")
        _ = flags.take("--json")
        do {
            try flags.finish()
        } catch let EnvCommandParseError.usage(message) {
            throw EnvCommandParseError.usage(
                message + " Accepted: --tool, --command, --platform, --runtime-id, --json."
                    + " See `amoo capabilities --help`."
            )
        }
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
