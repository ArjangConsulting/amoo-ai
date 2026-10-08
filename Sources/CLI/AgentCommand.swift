import Foundation

/// `amoo agent install` writes the bundled subagents (and the skills they rely on) in each AI
/// client's native format; `amoo agent render` regenerates the files committed in the plugin.
struct AgentInstallOptions: Equatable {
    var target: String = FileManager.default.currentDirectoryPath
    var scope: AgentScope = .project
    var homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    var clients: [AgentClient] = AgentClient.allCases
    var agents: [String] = AgentDefinition.all.map(\.name)
    var force = false
    var dryRun = false
    var json = false
    var executablePath: String = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""

    /// The directory agent paths are relative to.
    var root: URL {
        URL(fileURLWithPath: scope == .user ? homeDirectory : target)
    }
}

struct AgentInstallReport: Encodable {
    struct File: Encodable {
        var path: String
        var action: String
    }

    var ok: Bool
    var files: [File]
    var error: String?
}

/// One file the installer would write: the destination and its bytes.
struct AgentInstallFile: Equatable {
    var destination: URL
    var contents: Data
}

func renderAgentHelp() -> String {
    """
    Usage: amoo agent install [--target <repo> | --user] [--client <name>]... [--agent <name>]...
                              [--dry-run] [--force] [--json] [--binary <absolute-path>]
           amoo agent render --out <plugin-dir>
           amoo agent validate-report --report <report.json> --run-id <uuid> --checks <ids> [--json]
           amoo agent evidence --path <absolute-file> --run-id <uuid> --checks <ids>

    install  Writes the amoo subagents, in each client's own format, plus the skills they use.
             --target <repo>  project scope (default: current directory); commit the files
             --user           user scope: your home directory, for every project
             --client         claude, cursor, codex, copilot, gemini, opencode, or all (default);
                              repeat or comma-separate to pick several
             --agent          amoo, device-verifier, or all (default)
             --binary         absolute MCP binary path (default: this executable); shell aliases do not apply
             --dry-run        report what would change and write nothing
             --force          replace files that differ (local edits are otherwise kept)

               claude    .claude/agents/<name>.md           skills: .claude/skills/
               cursor    .cursor/agents/<name>.md           skills: .agents/skills/
               codex     .codex/agents/<name>.toml          skills: .agents/skills/
               copilot   .github/agents/<name>.agent.md     (user: ~/.copilot/agents/)
               gemini    .gemini/agents/<name>.md
               opencode  .opencode/agents/<name>.md         (user: ~/.config/opencode/agents/)

             Where the client allows it, the amoo agent starts its own `amoo mcp serve`, so the
             main session never loads amoo's tools. Plugin installs (see README) need none of this.

    render   Regenerates the client-specific agent files committed in the plugin directory.
    """
}

/// Where the bundled plugin lives: `plugins/amoo` in a source checkout, or
/// `share/amoo/plugins/amoo` in an installed prefix — found by walking up from the executable.
func agentAssetsRoot(
    executableURL: URL? = Bundle.main.executableURL,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath
) -> URL? {
    var roots: [URL] = []
    if var directory = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
        for _ in 0 ..< 6 {
            roots += [
                directory.appendingPathComponent("plugins/amoo"),
                directory.appendingPathComponent("share/amoo/plugins/amoo")
            ]
            directory.deleteLastPathComponent()
        }
    }
    roots.append(URL(fileURLWithPath: currentDirectoryPath).appendingPathComponent("plugins/amoo"))
    return roots.first { root in
        AgentDefinition.all.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.sourcePath).path)
        }
    }
}

/// Every file `options` would install, de-duplicated by destination.
func agentInstallPlan(_ options: AgentInstallOptions, assetsRoot: URL) throws -> [AgentInstallFile] {
    let definitions = AgentDefinition.all.filter { options.agents.contains($0.name) }
    var files: [AgentInstallFile] = []
    var seen: Set<String> = []
    func add(_ file: AgentInstallFile) {
        if seen.insert(file.destination.path).inserted {
            files.append(file)
        }
    }
    for definition in definitions {
        let path = definition.sourcePath
        let text = try String(contentsOf: assetsRoot.appendingPathComponent(path), encoding: .utf8)
        let source = try AgentSource(parsing: text, file: path)
        for client in options.clients {
            let rendered = try AgentRenderer.render(
                source,
                definition: definition,
                for: client,
                scope: options.scope,
                executablePath: options.executablePath
            )
            add(.init(
                destination: options.root.appendingPathComponent(rendered.path),
                contents: Data(rendered.contents.utf8)
            ))
            for skill in definition.skills {
                let skillRoot = assetsRoot.appendingPathComponent("skills/\(skill)")
                let destinationRoot = options.root
                    .appendingPathComponent(AgentRenderer.skillsDirectory(for: client))
                    .appendingPathComponent(skill)
                for relative in try skillFiles(in: skillRoot) {
                    try add(.init(
                        destination: destinationRoot.appendingPathComponent(relative),
                        contents: Data(contentsOf: skillRoot.appendingPathComponent(relative))
                    ))
                }
            }
        }
    }
    return files
}

/// Regular files under a skill directory, as sorted relative paths.
private func skillFiles(in directory: URL) throws -> [String] {
    let base = directory.resolvingSymlinksInPath().path
    guard let enumerator = FileManager.default.enumerator(atPath: base) else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
    }
    var paths: [String] = []
    while let relative = enumerator.nextObject() as? String {
        var isDirectory: ObjCBool = false
        let full = (base as NSString).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue,
           !relative.hasSuffix(".DS_Store") {
            paths.append(relative)
        }
    }
    guard !paths.isEmpty else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
    }
    return paths.sorted()
}

func runAgentInstall(_ options: AgentInstallOptions, assetsRoot: URL? = agentAssetsRoot()) -> CLIResult {
    var report = AgentInstallReport(ok: false, files: [])
    guard let assetsRoot else {
        report.error = "Cannot find the bundled amoo plugin (plugins/amoo/agents/amoo.md) next to amoo."
        return agentInstallResult(report, json: options.json)
    }
    do {
        for file in try agentInstallPlan(options, assetsRoot: assetsRoot) {
            let existing = try? Data(contentsOf: file.destination)
            let action: String
            if existing == file.contents {
                action = "unchanged"
            } else if existing != nil, !options.force {
                action = "skipped (differs; use --force)"
            } else if options.dryRun {
                action = existing == nil ? "would install" : "would update"
            } else {
                try FileManager.default.createDirectory(
                    at: file.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.contents.write(to: file.destination, options: .atomic)
                action = existing == nil ? "installed" : "updated"
            }
            report.files.append(.init(path: file.destination.path, action: action))
        }
        report.ok = true
    } catch {
        report.error = "\(error)"
    }
    return agentInstallResult(report, json: options.json)
}

/// Writes the client-specific agent files that are committed inside the plugin directory.
func runAgentRender(outputDirectory: URL, assetsRoot: URL) -> CLIResult {
    do {
        let sources = try AgentDefinition.all.map { definition in
            let text = try String(
                contentsOf: assetsRoot.appendingPathComponent(definition.sourcePath),
                encoding: .utf8
            )
            return try (AgentSource(parsing: text, file: definition.sourcePath), definition)
        }
        var written: [String] = []
        for file in try AgentRenderer.pluginFiles(sources) {
            let destination = outputDirectory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(file.contents.utf8).write(to: destination, options: .atomic)
            written.append("rendered: \(destination.path)")
        }
        return CLIResult(output: written.joined(separator: "\n"), exitCode: 0)
    } catch {
        return CLIResult(output: "agent render failed: \(error)", exitCode: 1)
    }
}

private func agentInstallResult(_ report: AgentInstallReport, json: Bool) -> CLIResult {
    let human = report.error.map { "agent install failed: \($0)" }
        ?? report.files.map { "\($0.action): \($0.path)" }.joined(separator: "\n")
    return CLIResult(output: json ? renderJSON(report) : human, exitCode: report.ok ? 0 : 1)
}

func parseAgentInstallOptions(_ args: [String]) throws -> AgentInstallOptions {
    var flags = EnvFlagReader(args)
    var options = AgentInstallOptions()
    let target = try flags.value("--target")
    if let target {
        options.target = target
    }
    if flags.take("--user") {
        guard target == nil else {
            throw EnvCommandParseError.usage("--target and --user cannot be combined.")
        }
        options.scope = .user
    }
    var clients: [AgentClient] = []
    while let raw = try flags.value("--client") {
        clients += try parseAgentList(raw, all: AgentClient.allCases, flag: "--client") { AgentClient(rawValue: $0) }
    }
    if !clients.isEmpty {
        options.clients = clients
    }
    var agents: [String] = []
    while let raw = try flags.value("--agent") {
        let names = AgentDefinition.all.map(\.name)
        agents += try parseAgentList(raw, all: names, flag: "--agent") { names.contains($0) ? $0 : nil }
    }
    if !agents.isEmpty {
        options.agents = agents
    }
    if let path = try flags.value("--binary") {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw EnvCommandParseError.usage("--binary requires an absolute path to an executable.")
        }
        options.executablePath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
    options.force = flags.take("--force")
    options.dryRun = flags.take("--dry-run")
    options.json = flags.take("--json")
    try flags.finish()
    return options
}

private func parseAgentList<T>(
    _ raw: String,
    all: [T],
    flag: String,
    parse: (String) -> T?
) throws -> [T] {
    try raw.split(separator: ",", omittingEmptySubsequences: false).flatMap { token -> [T] in
        let name = token.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "all" {
            return all
        }
        guard let value = parse(name) else {
            throw EnvCommandParseError.usage("\(flag): unknown value '\(name)'.")
        }
        return [value]
    }
}

func handleAgentCommand(remaining: [String]) -> CLIResult {
    guard let subcommand = remaining.first, !isHelpRequest(remaining) else {
        return CLIResult(output: renderAgentHelp(), exitCode: isHelpRequest(remaining) ? 0 : 64)
    }
    let args = Array(remaining.dropFirst())
    switch subcommand {
    case "validate-report":
        return runAgentReportValidation(args)
    case "evidence":
        return runAgentEvidenceCapture(args)
    case "install":
        do {
            return try runAgentInstall(parseAgentInstallOptions(args))
        } catch {
            return agentUsageError(error)
        }
    case "render":
        var flags = EnvFlagReader(args)
        do {
            guard let out = try flags.value("--out") else {
                return CLIResult(output: renderAgentHelp(), exitCode: 64)
            }
            try flags.finish()
            guard let assetsRoot = agentAssetsRoot() else {
                return CLIResult(output: "Cannot find the bundled amoo plugin (plugins/amoo).", exitCode: 1)
            }
            return runAgentRender(outputDirectory: URL(fileURLWithPath: out), assetsRoot: assetsRoot)
        } catch {
            return agentUsageError(error)
        }
    default:
        return CLIResult(output: renderAgentHelp(), exitCode: 64)
    }
}

/// The flag reader is shared with `amoo env`, whose error text appends env help; show ours.
private func agentUsageError(_ error: any Error) -> CLIResult {
    guard case let .usage(message)? = error as? EnvCommandParseError else {
        return CLIResult(output: "\(error)", exitCode: 64)
    }
    return CLIResult(output: message + "\n\n" + renderAgentHelp(), exitCode: 64)
}
