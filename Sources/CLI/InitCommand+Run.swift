import AmooCore
import Foundation

/// Host seams for the guided flow; tests replace all of them.
struct InitRuntime {
    var discovery: InitDiscovery
    var prompter: any CLIPrompting
    var isInteractive: () -> Bool
    var setup: (EnvUpOptions) async -> CLIResult
    var now: () -> Date
    var detectedClients: () -> [AgentClient]
    var installAgents: (AgentInstallOptions) -> CLIResult
    var assetsRoot: URL?

    static func live() -> Self {
        Self(
            discovery: .live(),
            prompter: StdioPrompter(),
            isInteractive: isInteractiveStdin,
            setup: { await runEnvUp($0) },
            now: Date.init,
            detectedClients: { detectInstalledAgentClients() },
            installAgents: { runAgentInstall($0) },
            assetsRoot: agentAssetsRoot()
        )
    }
}

private let cancelledResult = CLIResult(output: "Cancelled. No device was touched.", exitCode: 1)

/// `amoo init [flags]`: collect (or require) the inputs, validate before leasing anything, confirm,
/// then reuse `env up` per device.
func runInitCommand(_ args: [String], runtime: InitRuntime = .live()) async -> CLIResult {
    let request: InitRequest
    do { request = try parseInitRequest(args) } catch {
        return CLIResult(output: "\(error)\n\n" + renderInitHelp(), exitCode: 64)
    }
    // --json promises a single JSON document on stdout, so it can never share the terminal with prompts.
    let interactive = !request.nonInteractive && !request.json && runtime.isInteractive()
    let agentsFile = request.agentsFile.map { absoluteInitPath($0) }
        ?? FileManager.default.currentDirectoryPath + "/AGENTS.md"

    let complete: InitRequest
    switch await collectInitRequest(request, interactive: interactive, agentsFile: agentsFile, runtime: runtime) {
    case let .success(value): complete = value
    case let .failure(refusal): return refusal.result
    }
    let requests = [complete] + complete.additionalRequests
    // Validate every platform before any lease is acquired.
    for item in requests {
        if case let .failure(failure) = await buildInitPlan(item, discovery: runtime.discovery) {
            return InitRefusal(
                message: "Cannot start:\n" + failure.issues.joined(separator: "\n"),
                code: 1,
                json: item.json
            ).result
        }
    }
    var results: [CLIResult] = []
    for item in requests {
        let result = await runCompletedInit(item, interactive: interactive, agentsFile: agentsFile, runtime: runtime)
        results.append(result)
        if result.output == cancelledResult.output {
            break
        }
    }
    return CLIResult(
        output: results.map(\.output).joined(separator: "\n\n"),
        exitCode: results.map(\.exitCode).max() ?? 0
    )
}

private func runCompletedInit(
    _ complete: InitRequest,
    interactive: Bool,
    agentsFile: String,
    runtime: InitRuntime
) async -> CLIResult {
    if interactive {
        runtime.prompter.say("\nChecking the app and devices…")
    }
    let plan: InitPlan
    switch await buildInitPlan(complete, discovery: runtime.discovery) {
    case let .success(built): plan = built
    case let .failure(failure):
        let message = "Cannot start:\n" + failure.issues.map { "  - \($0)" }.joined(separator: "\n")
        return InitRefusal(message: message, code: 1, json: complete.json).result
    }
    if complete.dryRun {
        return CLIResult(
            output: complete.json ? renderJSON(InitPlanReport(plan)) : renderInitPlan(plan),
            exitCode: plan.problems.isEmpty ? 0 : 1
        )
    }

    if interactive {
        runtime.prompter.say("\n" + renderInitPlan(plan) + "\n")
    }
    let skills = chooseSkills(complete, interactive: interactive, runtime: runtime)
    var saveLocations = complete.save == true
    if interactive {
        guard let save = confirmInit(plan, complete, agentsFile: agentsFile, prompter: runtime.prompter) else {
            return cancelledResult
        }
        saveLocations = save
    }
    let result = await runInit(
        plan.options,
        setup: runtime.setup,
        onProgress: interactive ? { runtime.prompter.say($0) } : nil
    )
    return finishInit(
        withSkills(result, skills, runtime: runtime),
        plan: plan,
        save: saveLocations,
        interactive: interactive,
        agentsFile: agentsFile
    )
}

/// Installs the AI client files after the devices are ready, folding the outcome into the result.
private func withSkills(_ result: CLIResult, _ skills: SkillsChoice, runtime: InitRuntime) -> CLIResult {
    guard case let .install(options) = skills else { return result }
    let installed = runtime.installAgents(options)
    return CLIResult(
        output: result.output + "\n\nAI clients:\n" + installed.output,
        exitCode: max(result.exitCode, installed.exitCode)
    )
}

private enum SkillsChoice {
    case skip
    case install(AgentInstallOptions)
}

/// Whether to also install the amoo subagents and skills. In a terminal: asked (unless `--client`
/// or `--skills` already answered) and guided through the same picker as `amoo agent install`.
/// Headless: only when `--client` names the clients, since nothing can be asked.
private func chooseSkills(_ request: InitRequest, interactive: Bool, runtime: InitRuntime) -> SkillsChoice {
    guard request.skills != false else { return .skip }
    var options = AgentInstallOptions()
    options.clients = request.clients
    options.clientsGiven = !request.clients.isEmpty
    guard interactive else {
        guard options.clientsGiven else { return .skip }
        options.scopeGiven = true
        return .install(options)
    }
    if request.skills == nil, request.clients.isEmpty {
        let question = "Also set up the amoo subagents and skills for your AI clients (Claude Code, Codex, Cursor, …)?"
        guard runtime.prompter.confirm(question, default: true) == true else { return .skip }
    }
    guard let chosen = completeAgentInstallOptions(
        options,
        prompter: runtime.prompter,
        detected: runtime.detectedClients(),
        assetsRoot: runtime.assetsRoot
    ) else {
        runtime.prompter.say("Skipping the AI client setup.")
        return .skip
    }
    return .install(chosen)
}

private struct InitRefusal: Error {
    var message: String
    var code: Int32
    var json: Bool

    var result: CLIResult {
        CLIResult(
            output: json ? renderJSON(InitManifest(ok: false, results: [], error: message)) : message,
            exitCode: code
        )
    }
}

/// Fills the request in a terminal; headless, refuses unless every required input was given.
private func collectInitRequest(
    _ request: InitRequest,
    interactive: Bool,
    agentsFile: String,
    runtime: InitRuntime
) async -> Result<InitRequest, InitRefusal> {
    let saved = readInitLocations(agentsFile: agentsFile)
    guard interactive else {
        guard request.missing.isEmpty else {
            let message = await missingInputsMessage(request, discovery: runtime.discovery, saved: saved)
            return .failure(InitRefusal(message: message, code: 64, json: request.json))
        }
        return .success(request)
    }
    do {
        return try await .success(completeInitRequest(
            request,
            discovery: runtime.discovery,
            prompter: runtime.prompter,
            saved: saved,
            now: runtime.now()
        ))
    } catch {
        return .failure(InitRefusal(message: cancelledResult.output, code: 1, json: false))
    }
}

/// The two questions before leasing: record locations, and go ahead. Returns whether to record
/// locations, or nil when the user declined to proceed.
private func confirmInit(
    _ plan: InitPlan,
    _ request: InitRequest,
    agentsFile: String,
    prompter: any CLIPrompting
) -> Bool? {
    var save = request.save == true
    if request.save == nil {
        let shown = portableInitPath(agentsFile, relativeTo: FileManager.default.currentDirectoryPath)
        save = prompter.confirm(
            "Record the app and manifest locations in \(shown) so the next run (and agents) know where they are?",
            default: true
        ) ?? false
    }
    if !request.assumeYes {
        let proceed = prompter.confirm(
            "Set up \(plan.devices.count) device(s) now? This leases them and starts a companion on each",
            default: true
        )
        guard proceed == true else { return nil }
    }
    return save
}

/// Records locations (never device or lease ids) and, in a terminal, points at the next commands.
private func finishInit(
    _ result: CLIResult,
    plan: InitPlan,
    save: Bool,
    interactive: Bool,
    agentsFile: String
) -> CLIResult {
    var lines = [result.output]
    if save {
        let environment = plan.options.environment
        do {
            try saveInitLocations(
                InitSavedLocations(
                    platform: environment.platform,
                    appPath: environment.appPath,
                    appID: environment.appID,
                    manifestDirectory: plan.options.out
                        .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
                ),
                agentsFile: agentsFile
            )
            if interactive {
                lines.append("Saved locations to \(agentsFile).")
            }
        } catch {
            lines.append("Could not update \(agentsFile): \(error)")
        }
    }
    guard interactive else {
        return CLIResult(
            output: plan.options.environment.json ? result.output : lines.joined(separator: "\n"),
            exitCode: result.exitCode
        )
    }
    if let out = plan.options.out, let first = plan.options.devices.first {
        lines.append(
            """

            Next
              amoo init device --manifest \(shellQuoted(out)) --device \(first) --json current_app
              amoo init down --manifest \(shellQuoted(out))
            To record a session, run `init down` first, then MCP start_session on the same device.
            """
        )
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: result.exitCode)
}

/// Headless refusal text: every missing input at once, plus what this machine can offer so a caller
/// can fix the whole invocation in one retry.
private func missingInputsMessage(
    _ request: InitRequest,
    discovery: InitDiscovery,
    saved: InitSavedLocations?
) async -> String {
    var lines = ["amoo init needs these before it can run non-interactively:"]
    lines += request.missing.map { "  \($0)" }
    let remembered = request.platform.flatMap { saved?.forPlatform($0) } ?? saved
    if let saved = remembered, let app = saved.appPath {
        lines.append("AGENTS.md remembers: --app \(shellQuoted(app))"
            + (saved.appID.map { " --app-id \(shellQuoted($0))" } ?? ""))
    }
    if let platform = request.platform {
        if request.appPath == nil {
            let apps = discovery.apps(platform)
            lines.append("Built apps found: " + (apps.isEmpty ? "none" : "\n  " + apps.joined(separator: "\n  ")))
        }
        if request.devices.isEmpty {
            let free = await discovery.devices(platform).filter { $0.leasedBy == nil }
            lines
                .append("Unleased devices: " +
                    (free.isEmpty ? "none" : "\n  " + free.map(\.label).joined(separator: "\n  ")))
        }
    }
    lines.append("Run `amoo init` in a terminal for guided setup, or `amoo init --help`.")
    return lines.joined(separator: "\n")
}
