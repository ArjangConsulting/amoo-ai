import AmooCore
import Foundation
import MCP

/// Queryable contracts compiled into the running binary, shared by CLI and MCP discovery.
public enum CapabilityDiscovery {
    public static let definitions: [ToolDefinition] = [ToolDefinition(
        name: "get_capabilities",
        description: "Compact binary, invocation and assertion discovery without booting a device."
            + " Query tool=<name> for its exact argument schema; platform for provider support;"
            + " session_id for runtime identity. Prefer run_steps over separate calls for known sequences.",
        properties: [
            "tool": .init(type: "string", description: "Return only this tool's installed schema"),
            "platform": .init(type: "string", description: "ios, android or macos"),
            "session_id": .init(type: "string", description: "Include this managed runtime's identity")
        ]
    )]

    public static func query(tool: String? = nil, platform: Platform? = nil) throws -> Value {
        var fields: [String: Value] = ["schema_version": .int(1), "version": .string(AmooVersion.current)]
        if let tool {
            guard let definition = MCPServer().toolDefinitions().first(where: { $0.name == tool }) else {
                throw ToolExecutionError(code: "unknown_tool", message: "Unknown tool. Query get_capabilities first.")
            }
            fields["tool"] = .string(tool)
            if MCPServer.longLivedOnlyTools.contains(tool) {
                fields["cli"] = .string(MCPServer.longLivedOnlyMessage)
            }
            fields["arguments"] = definition.inputSchemaValue()
            fields["read_only"] = .bool(definition.readOnly == true)
        } else {
            fields["invocation"] = .object([
                "preferred": .string("amoo device --runtime-id <id> --json <tool> --arguments-json @arguments.json"),
                "lease": .string("amoo env up --platform <p> --json; amoo env down --runtime-id <id>"),
                "flow": .string("amoo flow <file.amoo.json> --runtime-id <id> --output-dir <dir>"),
                "runtime_flag": .string("--runtime-id"), "runtime_environment": .string("AMOO_RUNTIME_ID"),
                "schema_query": .string("amoo capabilities --tool <name>"),
                "batch": .string("run_steps: up to 20 steps; continue_on_error for independent checks")
            ])
            fields["efficient_tools"] = .object([
                "query": .string("find_elements: scoped selectors, limit, offset, response_mode=compact"),
                "incremental": .string("get_screen_context screen_token; assert_screen_changed from_token"),
                "screenshot": .string("take_screenshot: scale, output, return_image=false"),
                "coverage": .string("assertions with timeout_ms; tap_element expect_*; flow report.json"),
                "profiles": .array(ToolProfile.allCases.map { .string($0.rawValue) })
            ])
            fields["binary"] = .object([
                "path": AmooBuildInfo.current.executablePath.map(Value.string) ?? .null,
                "sha256": AmooBuildInfo.current.binarySHA256.map(Value.string) ?? .null,
                "process_id": .int(Int(AmooBuildInfo.current.pid))
            ])
        }
        if let platform {
            fields["assertions"] = assertionSupport(platform: platform)
        }
        return .object(fields)
    }

    private static func assertionSupport(platform: Platform) -> Value {
        var fields = providerSupport(InspectionCapabilities(platform: platform, provider: "platform_default"))
            .objectValue ?? [:]
        fields["platform"] = .string(platform.rawValue)
        return .object(fields)
    }

    static func providerSupport(_ capabilities: InspectionCapabilities) -> Value {
        var fields = capabilities.assertions.mapValues(Value.string)
        fields["provider"] = .string(capabilities.provider)
        fields["conditional_reason"] = .string("Requires the applicable property on the matched element."
            + " Unsupported properties never prove a check; use an explicit supported assertion.")
        return .object(fields)
    }
}

extension DriverToolExecutor {
    func executeCapabilities(arguments: [String: String]) async throws -> ToolResult {
        let platform = arguments["platform"].flatMap(Platform.init(rawValue:)) ?? defaultPlatform
        var fields = try CapabilityDiscovery.query(tool: arguments["tool"], platform: platform).objectValue ?? [:]
        if let id = arguments["session_id"] {
            _ = try await resolveDriver(arguments: arguments)
            if let session = await sessionManager?.session(id) {
                fields["runtime"] = .object([
                    "session_id": .string(id), "device_id": .string(session.deviceID),
                    "app_id": .string(session.appID), "platform": .string(session.platform.rawValue),
                    "ownership": .string("process"), "process_id": .int(Int(AmooBuildInfo.current.pid))
                ])
                fields["assertions"] = await CapabilityDiscovery
                    .providerSupport(session.driver.inspectionCapabilities())
            }
        }
        return .success("Installed capabilities.", structuredContent: .object(fields))
    }
}
