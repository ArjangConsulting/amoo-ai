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

    var real = false
    if store.isAvailable {
        let mock = "Mock account: values saved in \(AmooProjectConfig.fileName) and committed (never a real password)"
        let keychain = "Real account: values saved in your macOS Keychain; the file keeps only a reference"
        guard let kind = prompter.choose("Where should the values live?", options: [mock, keychain], default: 0)
        else { return credentialsCancelled }
        real = kind == 1
    } else {
        prompter.say("This platform has no credential store, so only a mock account can be added here.")
    }
    guard let identifierField = prompter.ask(
        "Field name agents use for the email or username",
        default: "email",
        validate: validateCredentialName
    ), let identifier = prompter.ask(
        "Email or username",
        default: nil,
        validate: { $0.isEmpty ? "Enter a value." : nil }
    ), let password = askPassword(prompter, confirmTwice: real), let launchAnswer = prompter.ask(
        "Launch environment amoo must set when it launches the app (KEY or KEY=VALUE, comma-separated; Enter for none)",
        default: "",
        validate: nil
    ) else { return credentialsCancelled }

    var fields: [String: CredentialField] = [:]
    if real {
        let service = "amoo.\(apps[0])"
        for (field, value) in [(identifierField, identifier), ("password", password)] {
            let account = "\(profile).\(field)"
            do {
                try await store.save(value, service: service, account: account, label: "amoo \(profile)#\(field)")
            } catch {
                return CLIResult(output: "Could not save '\(profile)#\(field)' to the Keychain: \(error)", exitCode: 1)
            }
            fields[field] = CredentialField(
                source: .keychain(service: service, account: account),
                fieldClass: field == "password" ? .secret : .identifier
            )
        }
    } else {
        fields[identifierField] = CredentialField(source: .literal(identifier), fieldClass: .identifier)
        fields["password"] = CredentialField(source: .literal(password), fieldClass: .secret)
    }
    config.profiles[profile] = CredentialProfile(
        apps: apps,
        requiresLaunchEnv: parseLaunchRequirements(launchAnswer),
        fields: fields
    )
    do {
        try config.write(to: file)
    } catch {
        return CLIResult(output: "Could not write \(file.path): \(error)", exitCode: 1)
    }
    var lines = [
        "Saved profile '\(profile)' to \(file.path).",
        "Agents sign in with credential=\(profile)#\(identifierField) and credential=\(profile)#password.",
        real
            ? "Commit \(file.lastPathComponent); it holds only Keychain references. If macOS later asks to let "
            + "amoo use these items, choose Always Allow, or run `amoo credentials check \(profile)` now."
            : "Commit \(file.lastPathComponent). Use a mock account only for a backend that accepts any password.",
        "Add or change accounts later with `amoo credentials add`."
    ]
    if !parseLaunchRequirements(launchAnswer).isEmpty {
        lines.append("amoo refuses this profile unless it launched the app with that environment.")
    }
    prompter.say(lines.joined(separator: "\n"))
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: 0)
}

/// Reports whether each field of a profile can be read, never the value.
func runCredentialsCheck(profile: String?, root: URL, store: any SecretStore) async -> CLIResult {
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
            let status: String
            switch credential.source {
            case .literal:
                status = "literal in \(AmooProjectConfig.fileName)"
            case let .keychain(service, account):
                do {
                    _ = try await store.load(service: service, account: account)
                    status = "found in Keychain"
                } catch SecretStoreError.notFound {
                    status = "missing from Keychain; run `amoo credentials add --profile \(name)`"
                    ok = false
                } catch SecretStoreError.unavailable {
                    status = "no credential store on this platform"
                    ok = false
                } catch {
                    status = "locked, or amoo was not allowed to read it"
                    ok = false
                }
            }
            lines.append("\(name)#\(field): \(status)")
        }
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: ok ? 0 : 1)
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
