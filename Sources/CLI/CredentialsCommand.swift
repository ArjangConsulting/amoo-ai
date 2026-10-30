import Foundation
import MCPServer
import StudioProtocol
import SwiftyTerminal

/// What `amoo init` already knows when it offers to add a sign-in profile.
struct CredentialsAddDefaults: Equatable {
    var profile: String?
    var appID: String?
}

/// `amoo credentials add|check`. Adding asks a person in a terminal for every value: amoo never
/// accepts a credential value as a flag, an environment variable, or from an agent.
func handleCredentialsCommand(
    remaining: [String],
    isInteractive: () -> Bool = isInteractiveStdin,
    prompter: any Prompting = Prompter(),
    store: KeychainCredentialStore = KeychainCredentialStore(),
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) async -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderCredentialsHelp(), exitCode: 0)
    }
    var arguments = Array(remaining.dropFirst())[...]
    switch remaining.first {
    case "add":
        var defaults = CredentialsAddDefaults()
        while let argument = arguments.popFirst() {
            switch argument {
            case "--profile": defaults.profile = arguments.popFirst()
            case "--app-id": defaults.appID = arguments.popFirst()
            default: return CLIResult(output: renderCredentialsHelp(), exitCode: 64)
            }
        }
        guard isInteractive() else {
            return CLIResult(
                output: "amoo credentials add needs a person at a terminal: it asks for each value and never "
                    + "accepts one as a flag or from an agent. Run it yourself in a terminal.",
                exitCode: 64
            )
        }
        return await runCredentialsAdd(prompter: prompter, defaults: defaults, root: currentDirectory, store: store)
    case "check":
        let profile = arguments.popFirst()
        guard arguments.isEmpty else { return CLIResult(output: renderCredentialsHelp(), exitCode: 64) }
        var interactive = store
        // A person is running this, so leave time to answer the macOS access prompt.
        interactive.timeout = .seconds(120)
        return await runCredentialsCheck(profile: profile, root: currentDirectory, store: interactive)
    default:
        return CLIResult(output: renderCredentialsHelp(), exitCode: 64)
    }
}

// swiftlint:disable:next function_body_length cyclomatic_complexity - one linear guided conversation.
func runCredentialsAdd(
    prompter: any Prompting,
    defaults: CredentialsAddDefaults,
    root: URL,
    store: any CredentialWriting
) async -> CLIResult {
    // The nearest file is the one written; the layered view is what agents see.
    let file = AmooProjectConfig.discover(from: root) ?? AmooProjectConfig.defaultLocation(from: root)
    var config = AmooProjectConfig()
    let visible: AmooProjectConfig
    do {
        if FileManager.default.fileExists(atPath: file.path) {
            config = try AmooProjectConfig.load(file)
        }
        let layers = AmooProjectConfig.discoverAll(from: root)
        visible = layers.isEmpty ? AmooProjectConfig() : try AmooProjectConfig.load(layers: layers)
    } catch {
        return CLIResult(output: "Fix the amoo.config.json files first: \(error)", exitCode: 1)
    }
    prompter.say(
        "Add a sign-in account for agents. What you type is saved to \(file.lastPathComponent) or your "
            + "Keychain; agents only ever see the profile name."
    )
    guard let profile = prompter.ask(
        "Profile name",
        default: defaults.profile ?? (visible.profiles.isEmpty ? "test-user" : nil),
        validate: validateCredentialName
    ) else { return credentialsCancelled }
    if visible.profiles[profile] != nil {
        let question = config.profiles[profile] != nil
            ? "Profile '\(profile)' exists. Replace it?"
            : "Profile '\(profile)' comes from an outer amoo.config.json. Override it in \(file.path)?"
        guard prompter.confirm(question, default: false) == true else {
            return credentialsCancelled
        }
    }
    guard let appsAnswer = prompter.ask(
        "App id(s) this account may sign in to (comma-separated)",
        default: defaults.appID,
        validate: { parseList($0).isEmpty ? "Enter at least one bundle or package id." : nil }
    ) else { return credentialsCancelled }
    let apps = parseList(appsAnswer)

    guard let storage = chooseStorage(prompter, keychainAvailable: store.isAvailable),
          let identifierField = prompter.ask(
              "Field name agents use for the email or username",
              default: "email",
              validate: validateCredentialName
          )
    else { return credentialsCancelled }
    let collected: CollectedAccount
    let naming = AccountNaming(profile: profile, identifierField: identifierField, service: "amoo.\(apps[0])")
    switch await collectAccount(storage, naming: naming, prompter: prompter, store: store) {
    case let .success(account): collected = account
    case let .failure(refusal): return refusal.result
    }
    guard let launchAnswer = prompter.ask(
        "Launch environment amoo must set when it launches the app (KEY or KEY=VALUE, comma-separated; Enter for none)",
        default: "",
        validate: nil
    ) else { return credentialsCancelled }
    config.profiles[profile] = CredentialProfile(
        apps: apps,
        requiresLaunchEnv: parseLaunchRequirements(launchAnswer),
        fields: collected.fields
    )
    do {
        try config.write(to: file)
    } catch {
        return CLIResult(output: "Could not write \(file.path): \(error)", exitCode: 1)
    }
    var lines = [
        "Saved profile '\(profile)' to \(file.path).",
        "Agents sign in with credential=\(profile)#\(identifierField) and credential=\(profile)#password."
    ] + collected.notes
    if !parseLaunchRequirements(launchAnswer).isEmpty {
        lines.append("amoo refuses this profile unless it launched the app with that environment.")
    }
    lines.append("Add or change accounts later with `amoo credentials add`.")
    prompter.say(lines.joined(separator: "\n"))
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: 0)
}

/// Where an account's values live. Plain text suits shared test accounts; environment variables
/// store nothing and never prompt; the Keychain encrypts them but macOS may ask to approve amoo.
enum AccountStorage: Equatable {
    case plainText, environment, keychain
}

private struct CollectedAccount {
    var fields: [String: CredentialField]
    var notes: [String]
}

private struct AccountNaming {
    var profile: String
    var identifierField: String
    /// The Keychain service for this account's items.
    var service: String
}

private struct CredentialsRefusal: Error {
    var result: CLIResult
}

private func chooseStorage(_ prompter: any Prompting, keychainAvailable: Bool) -> AccountStorage? {
    var options: [(AccountStorage, String)] = [
        (
            .plainText,
            "Plain text in \(AmooProjectConfig.fileName), committed: for mock, QA or staging test accounts "
                + "anyone with the repository may use"
        ),
        (
            .environment,
            "Environment variables: amoo reads them when an agent signs in; nothing is stored and macOS "
                + "never asks for approval"
        )
    ]
    if keychainAvailable {
        options.append((
            .keychain,
            "macOS Keychain: encrypted on this Mac; macOS may ask to approve amoo again "
                + "after amoo is rebuilt"
        ))
    }
    guard let index = prompter.choose(
        "Where should this account's values live?",
        options: options.map(\.1),
        default: 0
    ) else { return nil }
    return options[index].0
}

private func collectAccount(
    _ storage: AccountStorage,
    naming: AccountNaming,
    prompter: any Prompting,
    store: any CredentialWriting
) async -> Result<CollectedAccount, CredentialsRefusal> {
    let (profile, identifierField, service) = (naming.profile, naming.identifierField, naming.service)
    let cancelled = CredentialsRefusal(result: credentialsCancelled)
    if storage == .environment {
        return collectEnvironmentAccount(naming: naming, prompter: prompter)
    }
    guard let identifier = prompter.ask(
        "Email or username",
        default: nil,
        validate: { $0.isEmpty ? "Enter a value." : nil }
    ), let password = askPassword(prompter, confirmTwice: storage == .keychain) else { return .failure(cancelled) }
    guard storage == .keychain else {
        return .success(CollectedAccount(
            fields: [
                identifierField: CredentialField(source: .literal(identifier), fieldClass: .identifier),
                "password": CredentialField(source: .literal(password), fieldClass: .secret)
            ],
            notes: ["Commit \(AmooProjectConfig.fileName); it holds these values in plain text, so use only a test "
                + "account everyone who can read the repository may use."]
        ))
    }
    var fields: [String: CredentialField] = [:]
    for (field, value) in [(identifierField, identifier), ("password", password)] {
        let account = "\(profile).\(field)"
        do {
            try await store.save(value, service: service, account: account, label: "amoo \(profile)#\(field)")
        } catch {
            return .failure(CredentialsRefusal(result: CLIResult(
                output: "Could not save '\(profile)#\(field)' to the Keychain: \(error)",
                exitCode: 1
            )))
        }
        fields[field] = CredentialField(
            source: .keychain(service: service, account: account),
            fieldClass: field == "password" ? .secret : .identifier
        )
    }
    return .success(CollectedAccount(
        fields: fields,
        notes: ["Commit \(AmooProjectConfig.fileName); it holds only Keychain references. If macOS later asks to let "
            + "amoo use these items, choose Always Allow, or run `amoo credentials check \(profile)` now."]
    ))
}

/// An environment-backed account stores only variable names; no value is asked for.
private func collectEnvironmentAccount(
    naming: AccountNaming,
    prompter: any Prompting
) -> Result<CollectedAccount, CredentialsRefusal> {
    let (profile, identifierField) = (naming.profile, naming.identifierField)
    let cancelled = CredentialsRefusal(result: credentialsCancelled)
    guard let identifierVariable = prompter.ask(
        "Environment variable holding the email or username",
        default: environmentVariableName(profile: profile, field: identifierField),
        validate: validateEnvironmentName
    ), let passwordVariable = prompter.ask(
        "Environment variable holding the password",
        default: environmentVariableName(profile: profile, field: "password"),
        validate: validateEnvironmentName
    ) else { return .failure(cancelled) }
    return .success(CollectedAccount(
        fields: [
            identifierField: CredentialField(source: .environment(identifierVariable), fieldClass: .identifier),
            "password": CredentialField(source: .environment(passwordVariable), fieldClass: .secret)
        ],
        notes: [
            "Set \(identifierVariable) and \(passwordVariable) where amoo runs: in the `env` of your AI client's "
                + "amoo MCP server, or exported in the shell that runs `amoo device`. Prefer the MCP server's env: "
                + "a variable exported in an agent's own shell is one it could print.",
            "Commit \(AmooProjectConfig.fileName); it holds only the variable names."
        ]
    ))
}

/// `AMOO_<PROFILE>_<FIELD>`, upper-cased with anything outside `[A-Z0-9_]` turned into `_`.
func environmentVariableName(profile: String, field: String) -> String {
    let raw = "AMOO_\(profile)_\(field)".uppercased()
    return String(raw.unicodeScalars.map { scalar in
        CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "_"
    })
}

private func validateEnvironmentName(_ name: String) -> String? {
    CredentialField.isValidEnvironmentName(name) ? nil : "Use letters, digits and '_', not starting with a digit."
}

/// Reports whether each field of a profile can be read, never the value.
func runCredentialsCheck(
    profile: String?,
    root: URL,
    store: any SecretStore,
    environment: [String: String] = ProcessInfo.processInfo.environment
) async -> CLIResult {
    let files = AmooProjectConfig.discoverAll(from: root)
    guard !files.isEmpty else {
        return CLIResult(
            output: "No \(AmooProjectConfig.fileName) found. Add an account with `amoo credentials add`.",
            exitCode: 1
        )
    }
    let config: AmooProjectConfig
    do {
        config = try AmooProjectConfig.load(layers: files)
    } catch {
        return CLIResult(output: "\(error)", exitCode: 1)
    }
    let names = profile.map { [$0] } ?? config.profiles.keys.sorted()
    var lines: [String] = []
    var ok = true
    for name in names {
        guard let entry = config.profiles[name] else {
            lines.append("\(name): not in any \(AmooProjectConfig.fileName)")
            ok = false
            continue
        }
        for (field, credential) in entry.fields.sorted(by: { $0.key < $1.key }) {
            let (status, readable) = await fieldStatus(
                credential.source, profile: name, store: store, environment: environment
            )
            ok = ok && readable
            lines.append("\(name)#\(field): \(status)")
        }
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: ok ? 0 : 1)
}

/// One field's readability for `check`, and whether it counts as readable.
private func fieldStatus(
    _ source: CredentialField.Source,
    profile: String,
    store: any SecretStore,
    environment: [String: String]
) async -> (String, Bool) {
    switch source {
    case .literal:
        return ("literal in \(AmooProjectConfig.fileName)", true)
    case let .environment(variable):
        return environment[variable]?.isEmpty == false
            ? ("\(variable) is set here", true)
            : ("\(variable) is not set here; set it where amoo runs (the MCP server's env or the shell)", false)
    case let .keychain(service, account):
        do {
            _ = try await store.load(service: service, account: account)
            return ("found in Keychain", true)
        } catch SecretStoreError.notFound {
            return ("missing from Keychain; run `amoo credentials add --profile \(profile)`", false)
        } catch SecretStoreError.unavailable {
            return ("no credential store on this platform", false)
        } catch {
            return ("locked, or amoo was not allowed to read it", false)
        }
    }
}

private let credentialsCancelled = CLIResult(output: "Cancelled. No account was saved.", exitCode: 1)

private func askPassword(_ prompter: any Prompting, confirmTwice: Bool) -> String? {
    for _ in 0 ..< 3 {
        guard let password = prompter.askSecret("Password (not shown)") else { return nil }
        guard !password.isEmpty else {
            prompter.say("Enter a password.")
            continue
        }
        guard confirmTwice else { return password }
        guard let again = prompter.askSecret("Password again") else { return nil }
        if again == password {
            return password
        }
        prompter.say("The passwords did not match.")
    }
    return nil
}

private func validateCredentialName(_ name: String) -> String? {
    name.isEmpty || name.contains("#") || name.contains(where: \.isWhitespace)
        ? "Use a name without spaces or '#'."
        : nil
}

private func parseList(_ raw: String) -> [String] {
    raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// `KEY` means the key must be present; `KEY=VALUE` means it must equal VALUE.
func parseLaunchRequirements(_ raw: String) -> [String: String] {
    parseList(raw).reduce(into: [:]) { requirements, entry in
        let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.first, !key.isEmpty else { return }
        requirements[key] = parts.count == 2 ? parts[1] : "*"
    }
}

func renderCredentialsHelp() -> String {
    """
    Usage: amoo credentials add [--profile <name>] [--app-id <id>]
           amoo credentials check [<profile>]

    add    Asks, in a terminal, for an account agents may sign in with and saves it as a profile in
           amoo.config.json at the repository root. A mock account (any password works against a
           mock backend) is stored in the file; a real account is stored in your macOS Keychain and
           the file keeps only a reference. Values are never accepted as flags or from an agent.
    check  Reports whether each field of a profile can be read (found / missing / locked), never the
           value. Run it after rebuilding amoo so macOS can ask once to let amoo use the items.

    Agents sign in with credential="<profile>#<field>" on fill_field or set_text. See
    `amoo config --help` for the file format and docs/credentials.md for the rules amoo enforces.
    """
}
