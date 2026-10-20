import Foundation

/// One argument of a catalog tool, as Studio's console completes and validates it.
public struct StudioToolArgument: Codable, Equatable, Sendable {
    public let name: String
    /// JSON Schema type name: `string`, `integer`, `boolean`, `array`, or `object`.
    public let type: String
    public let description: String
    public let required: Bool
    /// Known values in canonical spelling. Only an exhaustive set is used to reject input.
    public let values: [String]?
    public let valuesAreExhaustive: Bool

    public init(
        name: String,
        type: String,
        description: String,
        required: Bool,
        values: [String]? = nil,
        valuesAreExhaustive: Bool = true
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.values = values
        self.valuesAreExhaustive = valuesAreExhaustive
    }
}

/// A tool as Studio sees it. Derived from the MCP tool registry so the console, the MCP server, and
/// the agent loop share one vocabulary.
public struct StudioToolSchema: Codable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let category: String
    /// Observes the device without changing it, so no screenshot is needed after it runs.
    public let readOnly: Bool
    /// Can destroy app or device state; the console refuses it and Studio asks for approval instead.
    public let destructive: Bool
    /// Whether the console can run it. Session and companion lifecycle tools are managed by Studio.
    public let replSupported: Bool
    /// The plan vocabulary name this tool records as (see `StudioTool`), such as `assert_not_visible`
    /// for `assert_absent`; nil when a compiled test plan cannot contain it.
    public let planTool: String?
    public let arguments: [StudioToolArgument]

    public init(
        name: String,
        title: String?,
        description: String,
        category: String,
        readOnly: Bool,
        destructive: Bool,
        replSupported: Bool,
        planTool: String?,
        arguments: [StudioToolArgument]
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.category = category
        self.readOnly = readOnly
        self.destructive = destructive
        self.replSupported = replSupported
        self.planTool = planTool
        self.arguments = arguments
    }
}

/// A console command that is not a device tool, such as `devices list`. Words in angle brackets
/// are slots the user fills, such as `<device>`.
public struct StudioReplBuiltin: Codable, Equatable, Sendable {
    public let command: String
    public let description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }

    var words: [String] {
        command.split(separator: " ").map(String.init)
    }

    /// The console's built-in commands, implemented by `LiveStudioAutomationService`.
    public static let all: [Self] = [
        .init(command: "help", description: "List console commands"),
        .init(command: "devices list", description: "Discover simulators, emulators, and devices"),
        .init(command: "devices inspect <device>", description: "Show one device's details"),
        .init(command: "tests validate", description: "Validate the active test"),
        .init(command: "tests run", description: "Run the active test on the selected device"),
        .init(command: "sessions list", description: "List recent Studio runs"),
        .init(command: "reports list", description: "List Studio reports"),
        .init(command: "providers inspect <provider>", description: "Show the selected provider profile")
    ]
}

public struct StudioToolCatalog: Codable, Equatable, Sendable {
    public let tools: [StudioToolSchema]
    public let builtins: [StudioReplBuiltin]

    public init(tools: [StudioToolSchema], builtins: [StudioReplBuiltin] = StudioReplBuiltin.all) {
        self.tools = tools
        self.builtins = builtins
    }
}

/// Supplies the tool catalog. Implemented outside `StudioProtocol`, which cannot see the MCP registry.
public protocol StudioToolCatalogProviding: Sendable {
    func tools() -> [StudioToolSchema]
}

/// An element on the current screen, offered as a value for selector arguments.
public struct StudioElementSuggestion: Codable, Equatable, Sendable {
    public let id: String?
    public let label: String?
    public let type: String?

    public init(id: String?, label: String?, type: String?) {
        self.id = id
        self.label = label
        self.type = type
    }
}

/// Lists elements on a device's current screen for completion. Implementations must answer only
/// from a device that is already connected, never by starting a companion, and should cache briefly.
public protocol StudioElementSuggesting: Sendable {
    func elements(deviceId: String, platform: String) async throws -> [StudioElementSuggestion]
    /// Drops cached elements after a command may have changed the screen.
    func invalidate(deviceId: String) async
}

// MARK: - Console completion and validation wire types

public struct StudioReplCompletionRequest: Codable, Sendable {
    public let line: String
    /// Caret position in UTF-16 code units, as Studio's editor reports it.
    public let cursor: Int
    public let selectedDeviceId: String?
    public let platform: String?

    public init(line: String, cursor: Int, selectedDeviceId: String? = nil, platform: String? = nil) {
        self.line = line
        self.cursor = cursor
        self.selectedDeviceId = selectedDeviceId
        self.platform = platform
    }
}

public enum StudioCompletionKind: String, Codable, Sendable {
    case tool
    case command
    case argument
    case value
    case element
    case device
}

public struct StudioCompletionItem: Codable, Equatable, Sendable {
    public let label: String
    public let insertText: String
    public let detail: String?
    public let documentation: String?
    public let kind: StudioCompletionKind
    /// Orders items before the client's own fuzzy ranking; required arguments sort first.
    public let sortText: String

    public init(
        label: String,
        insertText: String,
        detail: String? = nil,
        documentation: String? = nil,
        kind: StudioCompletionKind,
        sortText: String? = nil
    ) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
        self.sortText = sortText ?? label
    }
}

/// Items replace the UTF-16 range `replaceStart..<replaceEnd` of the line. The list is complete for
/// that range (`isIncomplete == false`), so the client filters it while the user keeps typing.
public struct StudioReplCompletionResult: Codable, Equatable, Sendable {
    public let replaceStart: Int
    public let replaceEnd: Int
    public let items: [StudioCompletionItem]
    public let isIncomplete: Bool

    public init(replaceStart: Int, replaceEnd: Int, items: [StudioCompletionItem], isIncomplete: Bool = false) {
        self.replaceStart = replaceStart
        self.replaceEnd = replaceEnd
        self.items = items
        self.isIncomplete = isIncomplete
    }

    public static func empty(at cursor: Int) -> Self {
        .init(replaceStart: cursor, replaceEnd: cursor, items: [])
    }
}

public struct StudioReplValidationRequest: Codable, Sendable {
    public let line: String

    public init(line: String) {
        self.line = line
    }
}

public enum StudioDiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
}

/// A problem in a console line, over the UTF-16 range `start..<end`.
public struct StudioReplDiagnostic: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let severity: StudioDiagnosticSeverity
    public let message: String

    public init(start: Int, end: Int, severity: StudioDiagnosticSeverity, message: String) {
        self.start = start
        self.end = end
        self.severity = severity
        self.message = message
    }
}

public struct StudioReplValidationResult: Codable, Equatable, Sendable {
    public let diagnostics: [StudioReplDiagnostic]

    public init(diagnostics: [StudioReplDiagnostic]) {
        self.diagnostics = diagnostics
    }
}
