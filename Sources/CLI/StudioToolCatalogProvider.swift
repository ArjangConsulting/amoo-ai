import MCPServer
import StudioProtocol

/// Builds Studio's tool catalog from the MCP registry, so the console, the MCP server, and the
/// agent loop share one vocabulary.
struct MCPStudioToolCatalog: StudioToolCatalogProviding {
    /// Plan names for MCP tools the session compiler records under a different name.
    static let planAliases = ["assert_absent": StudioTool.assertNotVisible.rawValue]

    /// Arguments Studio manages itself: the console routes by the selected device, not a session.
    private static let hiddenArguments: Set<String> = ["session_id"]

    /// Lifecycle tools Studio drives through its own workflows rather than the console.
    private static let consoleExcluded: Set<ToolCategory> = [.session, .companion]

    private let schemas: [StudioToolSchema]

    init(definitions: [ToolDefinition] = MCPServer().toolDefinitions()) {
        schemas = definitions.map(Self.schema)
    }

    func tools() -> [StudioToolSchema] {
        schemas
    }

    static func schema(for definition: ToolDefinition) -> StudioToolSchema {
        let required = Set(definition.required)
        let arguments = definition.properties
            .filter { !hiddenArguments.contains($0.key) }
            .sorted { lhs, rhs in
                // Required arguments first, then alphabetical, so completion and help read naturally.
                let lhsRequired = required.contains(lhs.key)
                let rhsRequired = required.contains(rhs.key)
                return lhsRequired == rhsRequired ? lhs.key < rhs.key : lhsRequired
            }
            .map { name, property in
                StudioToolArgument(
                    name: name,
                    type: property.type,
                    description: property.description,
                    required: required.contains(name),
                    values: property.values,
                    valuesAreExhaustive: property.valuesAreExhaustive
                )
            }
        let category = definition.category
        return StudioToolSchema(
            name: definition.name,
            title: definition.title,
            description: definition.description,
            category: category?.rawValue ?? "other",
            readOnly: definition.readOnly ?? false,
            destructive: definition.destructive ?? false,
            replSupported: category.map { !consoleExcluded.contains($0) } ?? true,
            planTool: StudioTool(rawValue: definition.name)?.rawValue ?? planAliases[definition.name],
            arguments: arguments
        )
    }
}
