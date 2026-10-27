import Foundation
import SwiftyTerminal

/// Display names for the guided picker.
func agentClientTitle(_ client: AgentClient) -> String {
    switch client {
    case .claude: "Claude Code"
    case .cursor: "Cursor"
    case .codex: "Codex"
    case .copilot: "GitHub Copilot"
    case .gemini: "Gemini CLI"
    case .opencode: "OpenCode"
    }
}

/// Clients that look installed on this Mac, judged by their per-user configuration directory.
func detectInstalledAgentClients(
    home: String = FileManager.default.homeDirectoryForCurrentUser.path,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> [AgentClient] {
    let markers: [AgentClient: String] = [
        .claude: ".claude", .cursor: ".cursor", .codex: ".codex",
        .copilot: ".copilot", .gemini: ".gemini", .opencode: ".config/opencode"
    ]
    return AgentClient.allCases.filter { markers[$0].map { exists(home + "/" + $0) } ?? false }
}

/// Asks which AI clients to set up and where, keeping anything already given as a flag.
/// Returns nil when input ends or the user declines the final confirmation.
func completeAgentInstallOptions(
    _ options: AgentInstallOptions,
    prompter: some Prompting,
    detected: [AgentClient],
    assetsRoot: URL?
) -> AgentInstallOptions? {
    var result = options
    guard let scoped = chooseAgentInstallScope(result, prompter: prompter) else { return nil }
    result = scoped
    if !options.clientsGiven {
        let all = AgentClient.allCases
        var labels = all.map { agentClientTitle($0) + (detected.contains($0) ? " (detected)" : "") }
        if !detected.isEmpty {
            labels.append("All detected")
        }
        let defaults = detected.isEmpty ? Array(all.indices) : [all.count]
        guard let picked = prompter.chooseMany(
            "AI clients to set up the amoo subagents and skills for",
            options: labels,
            defaults: defaults
        )
        else { return nil }
        result.clients = all.enumerated().compactMap { index, client in
            let selected = picked.contains(index) || (picked.contains(all.count) && detected.contains(client))
            return selected ? client : nil
        }
        result.clientsGiven = true
    }
    // Show exactly what would change before writing anything.
    var preview = result
    preview.dryRun = true
    preview.json = false
    prompter.say("\n" + runAgentInstall(preview, assetsRoot: assetsRoot).output + "\n")
    guard prompter.confirm("Install these files?", default: true) == true else { return nil }
    return result
}

func chooseAgentInstallScope(
    _ options: AgentInstallOptions,
    prompter: some Prompting
) -> AgentInstallOptions? {
    var result = options
    if !options.scopeGiven {
        guard let index = prompter.choose(
            "Install for",
            options: [
                "This repository (\(options.target)) — commit the files for your team",
                "Your home directory — every project on this Mac"
            ],
            default: 0
        ) else { return nil }
        result.scope = index == 0 ? .project : .user
        result.scopeGiven = true
    }
    return result
}

/// `amoo agent install`: guided in a terminal when `--client` is absent, otherwise exactly as before.
func runAgentInstallCommand(
    _ args: [String],
    prompter: any Prompting = Prompter(),
    interactive: () -> Bool = isInteractiveStdin,
    detected: () -> [AgentClient] = { detectInstalledAgentClients() },
    assetsRoot: URL? = agentAssetsRoot()
) -> CLIResult {
    let options: AgentInstallOptions
    do { options = try parseAgentInstallOptions(args) } catch {
        guard case let .usage(message)? = error as? EnvCommandParseError else {
            return CLIResult(output: "\(error)", exitCode: 64)
        }
        return CLIResult(output: message + "\n\n" + renderAgentHelp(), exitCode: 64)
    }
    guard !options.clientsGiven, !options.json, !options.nonInteractive, interactive() else {
        return runAgentInstall(options, assetsRoot: assetsRoot)
    }
    prompter.say("amoo agent install — add the amoo subagents and skills to your AI clients.\n")
    guard let scoped = chooseAgentInstallScope(options, prompter: prompter) else {
        return CLIResult(output: "Cancelled. No files were written.", exitCode: 1)
    }
    let status = probeAgentStatus(scoped, assetsRoot: assetsRoot)
    if let error = status.error {
        return CLIResult(output: error, exitCode: 1)
    }
    if status.found {
        let message = status.current
            ? "AI clients: already up to date (amoo \(status.availableVersion))."
            : "AI clients: installed files need review. Run amoo agent update."
        prompter.say(message)
        guard prompter.confirm("Install for additional AI clients?", default: false) == true else {
            return CLIResult(output: message, exitCode: 0)
        }
    }
    guard let chosen = completeAgentInstallOptions(
        scoped,
        prompter: prompter,
        detected: detected(),
        assetsRoot: assetsRoot
    ) else { return CLIResult(output: "Cancelled. No files were written.", exitCode: 1) }
    return runAgentInstall(chosen, assetsRoot: assetsRoot)
}
