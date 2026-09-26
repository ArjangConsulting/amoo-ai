import Foundation

/// `amoo agent install`: copies the reusable device-verifier agent + skill into a repo's `.claude/`.
struct AgentInstallOptions: Equatable {
    var target: String = FileManager.default.currentDirectoryPath
    var force = false
    var json = false
}

/// One bundled file and where it lands under the target repo.
struct AgentAsset: Equatable {
    var source: String
    var destination: String

    static let all = [
        Self(source: "agents/device-verifier.md", destination: ".claude/agents/device-verifier.md"),
        Self(source: "skills/device-verifier/SKILL.md", destination: ".claude/skills/device-verifier/SKILL.md")
    ]
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

func renderAgentHelp() -> String {
    """
    Usage: amoo agent install [--target <repo>] [--force] [--json]

    Installs the device-verifier subagent and its skill into <repo>/.claude/ (default: the
    current directory):
      .claude/agents/device-verifier.md
      .claude/skills/device-verifier/SKILL.md
    Existing files that differ are left alone unless --force.
    """
}

/// Where the bundled agent files live: a source checkout, or `share/amoo` in an installed
/// prefix — found by walking up from the executable, like the companion directory.
func agentAssetsRoot(
    executableURL: URL? = Bundle.main.executableURL,
    currentDirectoryPath: String = FileManager.default.currentDirectoryPath
) -> URL? {
    var roots: [URL] = []
    if var directory = executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
        for _ in 0 ..< 6 {
            roots += [directory, directory.appendingPathComponent("share/amoo")]
            directory.deleteLastPathComponent()
        }
    }
    roots.append(URL(fileURLWithPath: currentDirectoryPath))
    return roots.first { root in
        AgentAsset.all
            .allSatisfy { FileManager.default.fileExists(atPath: root.appendingPathComponent($0.source).path) }
    }
}

func runAgentInstall(_ options: AgentInstallOptions, assetsRoot: URL? = agentAssetsRoot()) -> CLIResult {
    var report = AgentInstallReport(ok: false, files: [])
    guard let assetsRoot else {
        report.error = "Cannot find the bundled agent files (agents/device-verifier.md) next to amoo."
        return agentInstallResult(report, json: options.json)
    }
    let target = URL(fileURLWithPath: options.target)
    do {
        for asset in AgentAsset.all {
            let source = assetsRoot.appendingPathComponent(asset.source)
            let destination = target.appendingPathComponent(asset.destination)
            let contents = try Data(contentsOf: source)
            let existing = try? Data(contentsOf: destination)
            let action: String
            if existing == contents {
                action = "unchanged"
            } else if existing != nil, !options.force {
                action = "skipped (differs; use --force)"
            } else {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: destination, options: .atomic)
                action = existing == nil ? "installed" : "updated"
            }
            report.files.append(.init(path: destination.path, action: action))
        }
        report.ok = true
    } catch {
        report.error = "\(error)"
    }
    return agentInstallResult(report, json: options.json)
}

private func agentInstallResult(_ report: AgentInstallReport, json: Bool) -> CLIResult {
    let human = report.error.map { "agent install failed: \($0)" }
        ?? report.files.map { "\($0.action): \($0.path)" }.joined(separator: "\n")
    return CLIResult(output: json ? renderJSON(report) : human, exitCode: report.ok ? 0 : 1)
}

func handleAgentCommand(remaining: [String]) -> CLIResult {
    guard remaining.first == "install", !isHelpRequest(remaining) else {
        return CLIResult(output: renderAgentHelp(), exitCode: isHelpRequest(remaining) ? 0 : 64)
    }
    var flags = EnvFlagReader(Array(remaining.dropFirst()))
    var options = AgentInstallOptions()
    do {
        options.target = try flags.value("--target") ?? options.target
        options.force = flags.take("--force")
        options.json = flags.take("--json")
        try flags.finish()
    } catch {
        return CLIResult(output: "\(error)", exitCode: 64)
    }
    return runAgentInstall(options)
}
