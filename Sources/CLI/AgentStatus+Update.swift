import Foundation
import SwiftyTerminal

/// Updates managed bytes and missing files while preserving edits and legacy installs by default.
func runAgentUpdate(
    _ options: AgentInstallOptions,
    assetsRoot: URL? = agentAssetsRoot(),
    overwriteUnrecorded: Bool = false
) -> CLIResult {
    let status = probeAgentStatus(options, assetsRoot: assetsRoot)
    guard status.error == nil, let assetsRoot else {
        return CLIResult(output: options.json ? renderJSON(status) : renderAgentStatus(status), exitCode: 1)
    }
    guard status.found else {
        return CLIResult(output: options.json ? renderJSON(status) : renderAgentStatus(status), exitCode: 0)
    }
    var selected = options
    selected.clients = status.clients
    selected.agents = status.agents
    selected.executablePath = status.binary ?? options.executablePath
    let states = Dictionary(uniqueKeysWithValues: status.files.map { ($0.path, $0.state) })
    do {
        let report = try writeAgentFiles(
            agentInstallPlan(selected, assetsRoot: assetsRoot),
            options: selected,
            shouldWrite: { file, _ in
                let state = states[file.destination.path]
                return options.force || state == .missing || state == .outdated
                    || (overwriteUnrecorded && state == .unrecorded)
            },
            skippedAction: { "skipped (\(states[$0.destination.path]?.rawValue ?? "edited"); use --force)" }
        )
        return agentInstallResult(report, json: options.json)
    } catch {
        return agentInstallResult(.init(ok: false, files: [], error: "\(error)"), json: options.json)
    }
}

func runAgentUpdateCommand(
    _ args: [String],
    prompter: any Prompting = Prompter(),
    interactive: () -> Bool = isInteractiveStdin,
    assetsRoot: URL? = agentAssetsRoot()
) -> CLIResult {
    do {
        let options = try parseAgentInstallOptions(args)
        let scopes = agentStatusScopes(options)
        let statuses = scopes.map { probeAgentStatus($0, assetsRoot: assetsRoot) }
        let count = statuses.flatMap(\.files).filter { $0.state == .unrecorded }.count
        var overwrite = false
        if count > 0, !options.force, !options.dryRun, !options.json, !options.nonInteractive, interactive() {
            overwrite = prompter.confirm(
                "\(count) files differ and have no install record — overwrite?", default: false
            ) == true
        }
        let results = zip(scopes, statuses).compactMap { scope, status -> CLIResult? in
            guard options.scopeGiven || status.found || status.error != nil else { return nil }
            return runAgentUpdate(scope, assetsRoot: assetsRoot, overwriteUnrecorded: overwrite)
        }
        if options.json {
            let objects = try results.map { try JSONSerialization.jsonObject(with: Data($0.output.utf8)) }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            return CLIResult(
                output: String(bytes: data, encoding: .utf8) ?? "[]",
                exitCode: results.map(\.exitCode).max() ?? 0
            )
        }
        return CLIResult(
            output: results.isEmpty ? "No AI client installs found." : results.map(\.output).joined(separator: "\n\n"),
            exitCode: results.map(\.exitCode).max() ?? 0
        )
    } catch { return agentUsageError(error) }
}
