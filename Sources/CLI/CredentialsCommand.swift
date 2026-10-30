import Foundation
import MCPServer
import StudioProtocol
import SwiftyTerminal

/// What `amoo init` already knows when it offers to add a sign-in profile.
struct CredentialsAddDefaults: Equatable {
    var profile: String?
    var appID: String?
}

/// The field a profile's sign-in name is typed from. It is any text (an email, a username, a phone
/// number), so the name says nothing about its shape.
let credentialLoginField = "login"

/// `amoo credentials add|check|remove`. Adding asks a person in a terminal for every value: amoo never
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
        return await handleCredentialsAdd(
            Array(arguments), isInteractive: isInteractive, prompter: prompter, store: store, root: currentDirectory
        )
    case "check":
        let profile = arguments.popFirst()
        guard arguments.isEmpty else { return CLIResult(output: renderCredentialsHelp(), exitCode: 64) }
        var interactive = store
        // A person is running this, so leave time to answer the macOS access prompt.
        interactive.timeout = .seconds(120)
        return await runCredentialsCheck(profile: profile, root: currentDirectory, store: interactive)
    case "remove":
        return await handleCredentialsRemove(
            Array(arguments), isInteractive: isInteractive, prompter: prompter, store: store, root: currentDirectory
        )
    default:
        return CLIResult(output: renderCredentialsHelp(), exitCode: 64)
    }
}

private func handleCredentialsAdd(
    _ remaining: [String],
    isInteractive: () -> Bool,
    prompter: any Prompting,
    store: KeychainCredentialStore,
    root currentDirectory: URL
) async -> CLIResult {
    var arguments = remaining[...]
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
}

private func handleCredentialsRemove(
    _ remaining: [String],
    isInteractive: () -> Bool,
    prompter: any Prompting,
    store: KeychainCredentialStore,
    root currentDirectory: URL
) async -> CLIResult {
    var arguments = remaining[...]
    guard let profile = arguments.popFirst()
    else { return CLIResult(output: renderCredentialsHelp(), exitCode: 64) }
    let assumeYes = arguments.first == "--yes"
    if assumeYes {
        arguments.removeFirst()
    }
    guard arguments.isEmpty else { return CLIResult(output: renderCredentialsHelp(), exitCode: 64) }
    guard assumeYes || isInteractive() else {
        return CLIResult(
            output: "amoo credentials remove asks before deleting; pass --yes to skip it.",
            exitCode: 64
        )
    }
    var interactive = store
    interactive.timeout = .seconds(120)
    return await runCredentialsRemove(
        profile: profile,
        root: currentDirectory,
        store: interactive,
        confirm: assumeYes ? { _ in true } : { prompter.confirm($0, default: false) == true }
    )
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

    guard let storage = chooseStorage(prompter, keychainAvailable: store.isAvailable) else {
        return credentialsCancelled
    }
    let identifierField = credentialLoginField
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
    let replaced = config.profiles[profile]
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
    // Keychain items the replaced profile used and the new one does not would otherwise linger.
    let kept = Set(collected.fields.values.compactMap(\.keychainItem))
    let stale = replaced.map { amooKeychainItems(of: $0, profile: profile) }?.filter { !kept.contains($0) } ?? []
    let cleanup = await deleteKeychainItems(stale, store: store)
    var lines = [
        "Saved profile '\(profile)' to \(file.path).",
        "Agents sign in with credential=\(profile)#\(identifierField) and credential=\(profile)#password."
    ] + collected.notes + cleanup
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
        "Sign-in name (any text: an email, username, phone number…)",
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
        "Environment variable holding the sign-in name",
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
           amoo credentials remove <profile> [--yes]

    add     Asks, in a terminal, for an account agents may sign in with: a sign-in name (any text)
            and a password, saved as a profile with fields `login` and `password` in the nearest
            amoo.config.json. You choose where the values live: plain text in the file (QA, staging
            or mock test accounts), environment variables (only the names are saved), or the macOS
            Keychain. Values are never accepted as flags or from an agent.
    check   Reports whether each field of a profile can be read (found / missing / locked / set),
            never the value. Run it after rebuilding amoo so macOS can ask once to let amoo use items.
    remove  Removes a profile from the amoo.config.json that defines it and deletes the Keychain
            items amoo created for it. Asks first unless --yes. Replacing a profile with `add` also
            deletes the Keychain items it no longer uses.

    Agents sign in with credential="<profile>#login" and credential="<profile>#password". See
    `amoo config --help` for the file format and docs/credentials.md for the rules amoo enforces.
    """
}
