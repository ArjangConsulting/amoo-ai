import AmooCore
import Foundation
import SwiftyTerminal

/// Host seams for the guided flow; tests replace all of them.
struct InitRuntime {
    var discovery: InitDiscovery
    var prompter: any Prompting
    var isInteractive: () -> Bool
    var setup: (EnvUpOptions) async -> CLIResult
    var now: () -> Date
    var detectedClients: () -> [AgentClient]
    var agentStatus: (URL) -> AgentStatusReport
    var updateAgents: (AgentInstallOptions) -> CLIResult
    var installAgents: (AgentInstallOptions) -> CLIResult
    var assetsRoot: URL?
    /// The `amoo credentials add` conversation, offered once during guided setup.
    var addCredentials: (CredentialsAddDefaults, URL, any Prompting) async -> CLIResult = { defaults, root, prompter in
        await runCredentialsAdd(prompter: prompter, defaults: defaults, root: root, store: KeychainCredentialStore())
    }

    static func live() -> Self {
        Self(
            discovery: .live(),
            prompter: Prompter(),
            isInteractive: isInteractiveStdin,
            setup: { await runEnvUp($0) },
            now: Date.init,
            detectedClients: { detectInstalledAgentClients() },
            agentStatus: { probeAgentStatus(AgentInstallOptions(target: $0.path)) },
            updateAgents: { runAgentUpdate($0) },
            installAgents: { runAgentInstall($0) },
            assetsRoot: agentAssetsRoot()
        )
    }
}

/// The platform repository named by `--repo`, below the directory that holds the orchestrator's `AGENTS.md`.
func initRepoDirectory(_ repo: String, agentsFile: String) -> URL {
    URL(fileURLWithPath: agentsFile).deletingLastPathComponent().appendingPathComponent(repo, isDirectory: true)
        .standardizedFileURL
}

private let cancelledResult = CLIResult(output: "Cancelled. No device was touched.", exitCode: 1)

/// `amoo init [flags]`: collect (or require) the inputs, validate before starting anything, confirm,
/// then reuse `env up` per device.
func runInitCommand(_ args: [String], runtime: InitRuntime = .live()) async -> CLIResult {
    var request: InitRequest
    do { request = try parseInitRequest(args) } catch {
        return initFailure(error, json: args.contains("--json"))
    }
    // --json promises a single JSON document on stdout, so it can never share the terminal with prompts.
    let interactive = !request.nonInteractive && !request.json && runtime.isInteractive()
    let agentsFile = request.agentsFile.map { absoluteInitPath($0) }
        ?? FileManager.default.currentDirectoryPath + "/AGENTS.md"
    if let repo = request.repo {
        let directory = initRepoDirectory(repo, agentsFile: agentsFile)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return InitRefusal(
                message: "--repo \(repo): no such directory at \(directory.path).",
                code: 64,
                json: request.json
            ).result
        }
        // The runtime manifest belongs to the platform repository, so `init down` finds it from `amoo.md`.
        request.out = request.out ?? directory.appendingPathComponent(".amoo.json").path
    }

    let complete: InitRequest
    switch await collectInitRequest(request, interactive: interactive, agentsFile: agentsFile, runtime: runtime) {
    case let .success(value): complete = value
    case let .failure(refusal): return refusal.result
    }
    let requests = [complete] + complete.additionalRequests
    // Validate every platform before any runtime is acquired.
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
    for (index, item) in requests.enumerated() {
        let result = await runCompletedInit(
            item,
            interactive: interactive,
            offerSignIn: index == 0,
            agentsFile: agentsFile,
            runtime: runtime
        )
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
    offerSignIn: Bool,
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
    if case .cancel = skills {
        return cancelledResult
    }
    var saveLocations = complete.save == true
    if interactive {
        guard let save = confirmInit(plan, complete, agentsFile: agentsFile, prompter: runtime.prompter) else {
            return cancelledResult
        }
        saveLocations = save
        if offerSignIn, !complete.assumeYes {
            await offerSignInAccount(appID: plan.options.environment.appID, agentsFile: agentsFile, runtime: runtime)
        }
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

/// Asks whether agents need to sign in, and runs `amoo credentials add` if so. Declining, cancelling
/// or failing never stops device setup; each ends by naming the command to run later.
private func offerSignInAccount(appID: String?, agentsFile: String, runtime: InitRuntime) async {
    let root = URL(fileURLWithPath: agentsFile).deletingLastPathComponent()
    let question = if case .configured = InitSignInStatus.inspect(root: root) {
        "Add another sign-in account for agents?"
    } else {
        "Will agents need to sign in to your app during tests? amoo can store a test account so they never see "
            + "its password."
    }
    guard runtime.prompter.confirm(question, default: false) == true else {
        runtime.prompter.say("Add a sign-in account any time with `amoo credentials add`.")
        return
    }
    let result = await runtime.addCredentials(CredentialsAddDefaults(appID: appID), root, runtime.prompter)
    if result.exitCode != 0 {
        runtime.prompter.say(result.output + "\nRun `amoo credentials add` to try again.")
    }
}

/// Installs the AI client files after the devices are ready, folding the outcome into the result.
private func withSkills(_ result: CLIResult, _ skills: SkillsChoice, runtime: InitRuntime) -> CLIResult {
    let installed: CLIResult
    switch skills {
    case let .install(options): installed = runtime.installAgents(options)
    case let .update(options): installed = runtime.updateAgents(options)
    case let .message(message):
        return CLIResult(output: result.output + "\n\n" + message, exitCode: result.exitCode)
    case .cancel, .skip: return result
    }
    return CLIResult(
        output: result.output + "\n\nAI clients:\n" + installed.output,
        exitCode: max(result.exitCode, installed.exitCode)
    )
}

private enum SkillsChoice {
    case cancel
    case skip
    case install(AgentInstallOptions)
    case update(AgentInstallOptions)
    case message(String)
}

/// Whether to also install the amoo subagents and skills. In a terminal: asked (unless `--client`
/// or `--skills` already answered) and guided through the same picker as `amoo agent install`.
/// Headless: only when `--client` names the clients, since nothing can be asked.
private func chooseSkills(_ request: InitRequest, interactive: Bool, runtime: InitRuntime) -> SkillsChoice {
    guard request.skills != false else { return .skip }
    var options = AgentInstallOptions()
    // Onboarding installs into this repository.
    options.scopeGiven = true
    options.clients = request.clients
    options.clientsGiven = !request.clients.isEmpty
    if request.skills == nil, request.clients.isEmpty, !request.json {
        let status = runtime.agentStatus(options.root)
        if status.found {
            return existingSkillsChoice(status, options: options, interactive: interactive, runtime: runtime)
        }
    }
    guard interactive else {
        guard options.clientsGiven else { return .skip }
        options.scopeGiven = true
        return .install(options)
    }
    if request.skills == nil, request.clients.isEmpty, !request.json {
        let question = "Also set up the amoo subagents and skills for your AI clients (Claude Code, Codex, Cursor, …)?"
        guard let answer = runtime.prompter.confirm(question, default: true) else { return .cancel }
        guard answer else { return .skip }
    }
    guard let chosen = completeAgentInstallOptions(
        options,
        prompter: runtime.prompter,
        detected: runtime.detectedClients(),
        assetsRoot: runtime.assetsRoot
    ) else {
        return .cancel
    }
    return .install(chosen)
}

private func existingSkillsChoice(
    _ status: AgentStatusReport,
    options: AgentInstallOptions,
    interactive: Bool,
    runtime: InitRuntime
) -> SkillsChoice {
    if let error = status.error {
        return .message(error)
    }
    if status.current {
        return .message("AI clients: already up to date (amoo \(status.availableVersion)).")
    }
    let hint = "AI clients: run amoo agent update to review and update installed files."
    guard interactive, status.updateCount > 0 else { return .message(hint) }
    runtime.prompter.say("AI clients: \(status.updateCount) files are outdated or missing.")
    guard let answer = runtime.prompter.confirm("Update \(status.updateCount) files?", default: true) else {
        return .cancel
    }
    guard answer else { return .message(hint) }
    var selected = options
    selected.clients = status.clients
    selected.agents = status.agents
    return .update(selected)
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
            let message = await missingInputsMessage(request, discovery: runtime.discovery)
            return .failure(InitRefusal(message: message, code: 64, json: request.json))
        }
        return .success(request)
    }
    do {
        let initialManifest = request.out ?? defaultInitManifestPath()
        try confirmExistingInitManifest(initialManifest, request: request, prompter: runtime.prompter)
        let completed = try await completeInitRequest(
            request,
            discovery: runtime.discovery,
            prompter: runtime.prompter,
            saved: saved,
            now: runtime.now()
        )
        if let manifest = completed.out, manifest != initialManifest {
            try confirmExistingInitManifest(manifest, request: request, prompter: runtime.prompter)
        }
        return .success(completed)
    } catch {
        return .failure(InitRefusal(message: cancelledResult.output, code: 1, json: false))
    }
}

private func confirmExistingInitManifest(
    _ path: String,
    request: InitRequest,
    prompter: any Prompting
) throws {
    guard !request.dryRun, FileManager.default.fileExists(atPath: path) else { return }
    let shown = portableInitPath(path, relativeTo: FileManager.default.currentDirectoryPath)
    guard prompter.confirm(
        "\(shown) already exists. Update it with this setup (existing device reservations are preserved)?",
        default: false
    ) == true else { throw InitWizardError.cancelled }
}

/// The two questions before starting runtimes: record locations, and go ahead. Returns whether to record
/// locations, or nil when the user declined to proceed.
private func confirmInit(
    _ plan: InitPlan,
    _ request: InitRequest,
    agentsFile: String,
    prompter: any Prompting
) -> Bool? {
    var save = request.save == true
    if request.save == nil {
        let shown = portableInitPath(agentsFile, relativeTo: FileManager.default.currentDirectoryPath)
        guard let answer = prompter.confirm(
            "Save project setup in \(shown) and discover test conventions in amoo.md (base class, IDs, helpers)?",
            default: true
        ) else { return nil }
        save = answer
    }
    if !request.assumeYes {
        let proceed = prompter.confirm(
            "Prepare \(plan.devices.count) selected device(s) for testing now?",
            default: true
        )
        guard proceed == true else { return nil }
    }
    return save
}

/// Records locations (never device or runtime ids) and, in a terminal, points at the next commands.
private func finishInit(
    _ result: CLIResult,
    plan: InitPlan,
    save: Bool,
    interactive: Bool,
    agentsFile: String
) -> CLIResult {
    var lines = [result.output]
    var exitCode = result.exitCode
    var jsonOutput = result.output
    if save {
        let environment = plan.options.environment
        let repo = plan.options.repo
        let repoDirectory = repo.map { initRepoDirectory($0, agentsFile: agentsFile) }
            ?? URL(fileURLWithPath: agentsFile).deletingLastPathComponent()
        do {
            try saveInitLocations(
                InitSavedLocations(
                    platform: environment.platform,
                    repoPath: repo,
                    appPath: environment.appPath,
                    appID: environment.appID,
                    manifestDirectory: plan.options.out
                        .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
                    framework: plan.options.framework
                ),
                agentsFile: agentsFile
            )
            try saveInitTestProfile(at: repoDirectory, platform: environment.platform)
            if let repo,
               let diagnostic = try recordInitRepo(
                   at: URL(fileURLWithPath: agentsFile).deletingLastPathComponent(),
                   platform: environment.platform,
                   repo: repo
               ) {
                lines.append(diagnostic)
            }
            if interactive {
                lines.append("Saved project setup to \(agentsFile).")
                lines
                    .append(
                        "Review amoo.md with your agent: confirm base class, IDs, helpers, and test target."
                    )
            }
        } catch {
            let message = "Could not save repository setup at \(agentsFile): \(error)"
            lines.append(message)
            exitCode = max(exitCode, 1)
            if var manifest = try? JSONDecoder().decode(InitManifest.self, from: Data(result.output.utf8)) {
                manifest.ok = false
                manifest.error = [manifest.error, message].compactMap(\.self).joined(separator: "\n")
                jsonOutput = renderJSON(manifest)
            }
        }
    }
    guard interactive else {
        return CLIResult(
            output: plan.options.environment.json ? jsonOutput : lines.joined(separator: "\n"),
            exitCode: exitCode
        )
    }
    let root = URL(fileURLWithPath: agentsFile).deletingLastPathComponent()
    lines.append(renderInitNextSteps(plan, signIn: InitSignInStatus.inspect(root: root)))
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: exitCode)
}

func renderInitNextSteps(_ plan: InitPlan, signIn: InitSignInStatus) -> String {
    let platform = plan.options.environment.platform.rawValue
    let commands = plan.options.devices.map { device in
        "  amoo companion warm --platform \(platform) --device \(shellQuoted(device))"
    }
    return """

    Prepare companions for faster test startup
    `companion warm` builds and installs the companion on each selected device.
    Run it ahead of time to move this work out of your next test session:
    \(commands.joined(separator: "\n"))
    It does not launch your app or keep a companion process running.

    Start using amoo
    Ask your AI agent: "Use amoo to inspect my app and verify [describe a flow]."
    Build your app with its normal Xcode or Gradle workflow, then give the agent
    the app identifier and build path so it can install and launch the right app.
    For reusable tests, ask the agent to record the flow and generate a test.

    Useful commands
      amoo device --help   Browse inspection, gestures, screenshots and assertions.
      amoo doctor          Check your local setup and diagnose connection problems.
    Review amoo.md with your agent to confirm test targets, base classes and helpers.
    """ + signIn.nextSteps
}

/// Headless refusal text: every missing input at once, plus the available devices.
private func missingInputsMessage(
    _ request: InitRequest,
    discovery: InitDiscovery
) async -> String {
    var lines = ["amoo init needs these before it can run non-interactively:"]
    lines += request.missing.map { "  \($0)" }
    if let platform = request.platform {
        if request.devices.isEmpty {
            let free = await discovery.devices(platform).filter { $0.controlledBy == nil }
            lines
                .append("Available devices: " +
                    (free.isEmpty ? "none" : "\n  " + free.map(\.label).joined(separator: "\n  ")))
        }
    }
    lines.append("Run `amoo init` in a terminal for guided setup, or `amoo init --help`.")
    return lines.joined(separator: "\n")
}
