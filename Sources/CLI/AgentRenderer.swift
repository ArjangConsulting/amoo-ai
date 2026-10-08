import Foundation

/// An AI coding client that `amoo agent install` can write a subagent for.
enum AgentClient: String, CaseIterable, Sendable {
    case claude
    case cursor
    case codex
    case copilot
    case gemini
    case opencode
}

/// Where agent files land: a repository (checked in, shared) or the user's home (all projects).
enum AgentScope: Equatable, Sendable {
    case project
    case user
}

/// Which flavour of an agent file to render. A plugin-bundled agent gets amoo's MCP server from
/// the plugin itself, so it never declares its own; a standalone file scopes it to the subagent.
enum AgentRenderMode: Equatable, Sendable {
    case standalone
    case plugin
}

/// A bundled agent: its canonical source (`agents/<name>.md` in the plugin, neutral frontmatter
/// with only `name` and `description`) plus the per-client settings the renderer adds.
struct AgentDefinition: Equatable, Sendable {
    var name: String
    /// Skill directories under the plugin's `skills/` that the agent relies on.
    var skills: [String]
    /// Start `amoo mcp serve` for this subagent only, where the client supports it.
    var scopedMCP: Bool
    var claudeModel: String?
    /// Claude Code `tools` allowlist; nil inherits the caller's tools.
    var claudeTools: String?
    var claudeDisallowedTools: String?

    static let amoo = Self(
        name: "amoo",
        skills: ["driving-amoo", "ios-accessibility", "android-accessibility"],
        scopedMCP: true,
        claudeModel: "sonnet",
        claudeTools: nil,
        claudeDisallowedTools: "Edit, NotebookEdit"
    )

    static let deviceVerifier = Self(
        name: "device-verifier",
        skills: ["device-verifier"],
        scopedMCP: false,
        claudeModel: "sonnet",
        claudeTools: "Bash, Read, Write, Glob, Grep",
        claudeDisallowedTools: nil
    )

    static let all = [amoo, deviceVerifier]

    var sourcePath: String {
        "agents/\(name).md"
    }
}

enum AgentRenderError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter(String)
    case missingField(String, file: String)
    case unsupportedBody(String)

    var description: String {
        switch self {
        case let .missingFrontmatter(file):
            "\(file): expected YAML frontmatter between '---' lines."
        case let .missingField(field, file):
            "\(file): frontmatter needs a single-line '\(field):'."
        case let .unsupportedBody(reason):
            reason
        }
    }
}

/// The canonical agent file, parsed: frontmatter `name` and `description`, and the prompt body.
struct AgentSource: Equatable, Sendable {
    var name: String
    var description: String
    var body: String
}

extension AgentSource {
    /// A deliberately small parser: the canonical frontmatter holds two single-line scalars, so
    /// no YAML dependency is needed. Other top-level keys are ignored.
    init(parsing text: String, file: String) throws {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
            throw AgentRenderError.missingFrontmatter(file)
        }
        var fields: [String: String] = [:]
        for line in lines[1 ..< end] where !line.hasPrefix(" ") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = Self.unquoted(value)
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw AgentRenderError.missingField("name", file: file)
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw AgentRenderError.missingField("description", file: file)
        }
        self.name = name
        self.description = description
        body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

/// One rendered file, with its path relative to the scope root (the repo, or the home directory).
struct RenderedAgentFile: Equatable, Sendable {
    var path: String
    var contents: String
}

/// Turns one canonical agent into each client's native subagent format.
enum AgentRenderer {
    static func agentDirectory(for client: AgentClient, scope: AgentScope) -> String {
        switch (client, scope) {
        case (.claude, _): ".claude/agents"
        case (.cursor, _): ".cursor/agents"
        case (.codex, _): ".codex/agents"
        case (.copilot, .project): ".github/agents"
        case (.copilot, .user): ".copilot/agents"
        case (.gemini, _): ".gemini/agents"
        case (.opencode, .project): ".opencode/agents"
        case (.opencode, .user): ".config/opencode/agents"
        }
    }

    /// Claude Code reads `.claude/skills`; the others read the shared Agent Skills directory.
    static func skillsDirectory(for client: AgentClient) -> String {
        client == .claude ? ".claude/skills" : ".agents/skills"
    }

    static func render(
        _ source: AgentSource,
        definition: AgentDefinition,
        for client: AgentClient,
        scope: AgentScope = .project,
        mode: AgentRenderMode = .standalone,
        executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""
    ) throws -> RenderedAgentFile {
        let directory = agentDirectory(for: client, scope: scope)
        let mcp = definition.scopedMCP && mode == .standalone
        guard !mcp || executablePath.hasPrefix("/") else {
            throw AgentRenderError.unsupportedBody("MCP configuration requires an absolute amoo executable path.")
        }
        switch client {
        case .claude:
            return .init(
                path: "\(directory)/\(source.name).md",
                contents: claude(source, definition, mcp: mcp, executable: executablePath)
            )
        case .cursor:
            return .init(path: "\(directory)/\(source.name).md", contents: cursor(source))
        case .codex:
            return try .init(
                path: "\(directory)/\(source.name).toml",
                contents: codex(source, mcp: mcp, executable: executablePath)
            )
        case .copilot:
            return .init(
                path: "\(directory)/\(source.name).agent.md",
                contents: copilot(source, mcp: mcp, executable: executablePath)
            )
        case .gemini:
            return .init(
                path: "\(directory)/\(source.name).md",
                contents: gemini(source, mcp: mcp, executable: executablePath)
            )
        case .opencode:
            return .init(path: "\(directory)/\(source.name).md", contents: opencode(source))
        }
    }

    /// The generated files committed inside the plugin directory (`amoo agent render`).
    static func pluginFiles(_ sources: [(AgentSource, AgentDefinition)]) throws -> [RenderedAgentFile] {
        try sources.map { source, definition in
            let file = try render(source, definition: definition, for: .copilot, mode: .plugin)
            return .init(path: "com.github.copilot/agents/\(source.name).agent.md", contents: file.contents)
        }
    }

    // MARK: - Per-client formats

    private static func claude(
        _ source: AgentSource,
        _ definition: AgentDefinition,
        mcp: Bool,
        executable: String
    ) -> String {
        var lines = ["name: \(source.name)", "description: \(quoted(source.description))"]
        let optional = [
            definition.claudeModel.map { "model: \($0)" },
            definition.claudeTools.map { "tools: \($0)" },
            definition.claudeDisallowedTools.map { "disallowedTools: \($0)" }
        ]
        lines += optional.compactMap(\.self)
        if mcp {
            lines += [
                "mcpServers:",
                "  - amoo:",
                "      type: stdio",
                "      command: \(quoted(executable))",
                "      args: [\"mcp\", \"serve\"]"
            ]
        }
        return markdown(frontmatter: lines, body: source.body)
    }

    private static func cursor(_ source: AgentSource) -> String {
        markdown(
            frontmatter: ["name: \(source.name)", "description: \(quoted(source.description))", "model: inherit"],
            body: source.body
        )
    }

    private static func codex(_ source: AgentSource, mcp: Bool, executable: String) throws -> String {
        guard !source.body.contains("'''") else {
            throw AgentRenderError.unsupportedBody(
                "agents/\(source.name).md: the body contains ''' and cannot be a TOML literal string."
            )
        }
        var lines = [
            "name = \(quoted(source.name))",
            "description = \(quoted(source.description))",
            "developer_instructions = '''",
            source.body + "'''"
        ]
        if mcp {
            // A cold companion build inside start_session outlasts Codex's default tool timeout.
            lines += [
                "",
                "[mcp_servers.amoo]",
                "command = \(quoted(executable))",
                "args = [\"mcp\", \"serve\"]",
                "tool_timeout_sec = 900"
            ]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func copilot(_ source: AgentSource, mcp: Bool, executable: String) -> String {
        var lines = ["name: \(source.name)", "description: \(quoted(source.description))"]
        if mcp {
            lines += [
                "mcp-servers:",
                "  amoo:",
                "    type: local",
                "    command: \(quoted(executable))",
                "    args: [\"mcp\", \"serve\"]",
                "    tools: [\"*\"]"
            ]
        }
        return markdown(frontmatter: lines, body: source.body)
    }

    private static func gemini(_ source: AgentSource, mcp: Bool, executable: String) -> String {
        // The defaults (10 minutes, 30 turns) are too short for a cold companion build.
        var lines = [
            "name: \(source.name)",
            "description: \(quoted(source.description))",
            "timeout_mins: 30",
            "max_turns: 80"
        ]
        if mcp {
            lines += ["mcpServers:", "  amoo:", "    command: \(quoted(executable))", "    args: [\"mcp\", \"serve\"]"]
        }
        return markdown(frontmatter: lines, body: source.body)
    }

    private static func opencode(_ source: AgentSource) -> String {
        markdown(
            frontmatter: [
                "description: \(quoted(source.description))",
                "mode: subagent",
                "permission:",
                "  edit: deny"
            ],
            body: source.body
        )
    }

    private static func markdown(frontmatter: [String], body: String) -> String {
        (["---"] + frontmatter + ["---", "", body]).joined(separator: "\n")
    }

    /// A double-quoted string valid in both YAML and TOML (basic string) syntax.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
