import AmooCore
import AmooLogging
import Foundation

/// Drift against freshly rendered bundled files, preserving evidence of local edits.
enum AgentFileState: String, Codable {
    case current, missing, outdated, edited, unrecorded
}

struct AgentStatusReport: Encodable {
    struct File: Encodable {
        var path: String
        var state: AgentFileState
    }

    var root: String
    var installedVersion: String?
    var availableVersion = AmooVersion.current
    var clients: [AgentClient] = []
    var agents: [String] = []
    var files: [File] = []
    var error: String?
    var installationFound = false

    var found: Bool {
        installationFound
    }

    var current: Bool {
        error == nil && files.allSatisfy { $0.state == .current }
    }

    var updateCount: Int {
        files.filter { [.outdated, .missing].contains($0.state) }.count
    }
}

extension AgentClient: Encodable {}

func probeAgentStatus(
    _ options: AgentInstallOptions,
    assetsRoot: URL? = agentAssetsRoot()
) -> AgentStatusReport {
    let logger = AmooLogger.forType(AgentStatusReport.self)
    logger.info("Inspecting AI client files", context: "root=\(options.root.path)")
    var report = AgentStatusReport(root: options.root.path)
    do {
        guard let assetsRoot else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let stamp = try AgentInstallStamp.read(in: options.root)
        var selected = options
        let installedClients = try AgentClient.allCases.filter { client in
            if stamp?.clients.contains(client.rawValue) == true {
                return true
            }
            return try AgentDefinition.all.contains { definition in
                let rendered = try AgentRenderer.render(
                    AgentSource(parsing: String(
                        contentsOf: assetsRoot.appendingPathComponent(definition.sourcePath), encoding: .utf8
                    ), file: definition.sourcePath),
                    definition: definition,
                    for: client,
                    scope: options.scope,
                    executablePath: options.executablePath
                )
                return FileManager.default
                    .fileExists(atPath: options.root.appendingPathComponent(rendered.path).path)
            }
        }
        selected.clients = options.clientsGiven ? options.clients : installedClients
        selected.agents = stamp?.agents ?? AgentDefinition.all.map(\.name)
        report.installationFound = stamp != nil || !installedClients.isEmpty
        report.clients = selected.clients
        report.agents = selected.agents
        report.installedVersion = stamp?.amooVersion
        for file in try agentInstallPlan(selected, assetsRoot: assetsRoot) {
            let disk = try readAgentFile(file.destination)
            let hash = stamp?.files[AgentInstallStamp.relativePath(file.destination, root: options.root)]
            let state: AgentFileState = if disk == file.contents {
                .current
            } else if let disk {
                hash.map { sha256Hex(disk) == $0 ? .outdated : .edited } ?? .unrecorded
            } else {
                .missing
            }
            report.files.append(.init(path: file.destination.path, state: state))
        }
        logger.info("Inspected AI client files", context: "root=\(options.root.path) files=\(report.files.count)")
    } catch {
        logger.error("AI client inspection failed", error: error, context: "root=\(options.root.path)")
        report.error = "Cannot inspect AI client install at \(options.root.path): \(error)"
    }
    return report
}

func renderAgentStatus(_ report: AgentStatusReport) -> String {
    if let error = report.error {
        return error
    }
    guard report.found else { return "No AI client install found at \(report.root)." }
    let version = "amoo \(report.installedVersion ?? "unknown") installed → \(report.availableVersion) available"
    return (["\(report.root): \(version)"] + report.files.map { "\($0.state.rawValue): \($0.path)" })
        .joined(separator: "\n")
}

func agentStatusScopes(_ options: AgentInstallOptions) -> [AgentInstallOptions] {
    guard !options.scopeGiven else { return [options] }
    var home = options
    home.scope = .user
    if options.root.standardizedFileURL == home.root.standardizedFileURL {
        return [options]
    }
    return [options, home]
}

func runAgentStatusCommand(_ args: [String], assetsRoot: URL? = agentAssetsRoot()) -> CLIResult {
    do {
        let options = try parseAgentInstallOptions(args)
        guard !options.force, !options.dryRun else {
            throw EnvCommandParseError.usage("agent status does not accept --force or --dry-run.")
        }
        let reports = agentStatusScopes(options).map { probeAgentStatus($0, assetsRoot: assetsRoot) }
            .filter { options.scopeGiven || $0.found || $0.error != nil }
        let output = options.json ? renderJSON(reports) : reports.map(renderAgentStatus).joined(separator: "\n\n")
        return CLIResult(
            output: output.isEmpty ? "No AI client installs found." : output,
            exitCode: reports.allSatisfy(\.current) ? 0 : 1
        )
    } catch { return agentUsageError(error) }
}

func handleAgentMaintenanceCommand(_ command: String, args: [String]) -> CLIResult {
    command == "status" ? runAgentStatusCommand(args) : runAgentUpdateCommand(args)
}
