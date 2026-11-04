import MCP

enum DeviceInvocationFlag: String, CaseIterable {
    case platform = "--platform"
    case port = "--port"
    case device = "--device"
    case runtimeID = "--runtime-id"
    case json = "--json"

    static var schema: Value {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: allCases.map { flag in
                let type = flag == .json ? "boolean" : flag == .port ? "integer" : "string"
                return (flag.rawValue, .object(["type": .string(type)]))
            })),
            "additionalProperties": .bool(false),
            "tool_arguments": .object([
                "--arguments-json": .string("JSON object or @path; mutually unique argument keys"),
                "--env": .string("Repeatable KEY=VALUE"), "--arg": .string("Repeatable launch argument")
            ])
        ])
    }
}
