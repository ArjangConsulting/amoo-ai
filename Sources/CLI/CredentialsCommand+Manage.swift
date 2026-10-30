import Foundation
import MCPServer
import StudioProtocol

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

/// Removes a profile from the nearest `amoo.config.json` that defines it, and deletes the Keychain
/// items amoo created for it. Items a hand-written profile points at, outside amoo's own
/// `amoo.<app id>` / `<profile>.<field>` naming, are never deleted.
func runCredentialsRemove(
    profile: String,
    root: URL,
    store: any CredentialWriting,
    confirm: (String) -> Bool
) async -> CLIResult {
    let files = AmooProjectConfig.discoverAll(from: root)
    var located: (file: URL, config: AmooProjectConfig)?
    for file in files {
        do {
            let config = try AmooProjectConfig.load(file)
            if config.profiles[profile] != nil {
                located = (file, config)
                break
            }
        } catch {
            return CLIResult(output: "Fix \(file.path) first: \(error)", exitCode: 1)
        }
    }
    guard var (file, config) = located, let entry = config.profiles[profile] else {
        return CLIResult(output: "No profile '\(profile)' in any \(AmooProjectConfig.fileName).", exitCode: 1)
    }
    let items = amooKeychainItems(of: entry, profile: profile)
    let question = "Remove profile '\(profile)' from \(file.path)"
        + (items.isEmpty ? "?" : " and delete the \(items.count) Keychain item(s) amoo created for it?")
    guard confirm(question) else {
        return CLIResult(output: "Cancelled. Nothing was removed.", exitCode: 1)
    }
    config.profiles[profile] = nil
    do {
        try config.write(to: file)
    } catch {
        return CLIResult(output: "Could not write \(file.path): \(error)", exitCode: 1)
    }
    var lines = await ["Removed profile '\(profile)' from \(file.path)."] + deleteKeychainItems(items, store: store)
    if files.dropFirst().contains(where: { (try? AmooProjectConfig.load($0).profiles[profile]) != nil }) {
        lines.append("An outer \(AmooProjectConfig.fileName) still defines '\(profile)'; agents now use that one.")
    }
    return CLIResult(
        output: lines.joined(separator: "\n"),
        exitCode: lines.contains { $0.hasPrefix("Could not") } ? 1 : 0
    )
}

struct KeychainItemReference: Hashable {
    var service: String
    var account: String
}

extension CredentialField {
    var keychainItem: KeychainItemReference? {
        guard case let .keychain(service, account) = source else { return nil }
        return KeychainItemReference(service: service, account: account)
    }
}

/// The Keychain items of `profile` that `amoo credentials add` named, sorted.
func amooKeychainItems(of profile: CredentialProfile, profile name: String) -> [KeychainItemReference] {
    profile.fields.values.compactMap(\.keychainItem)
        .filter { $0.service.hasPrefix("amoo.") && $0.account.hasPrefix("\(name).") }
        .sorted { ($0.service, $0.account) < ($1.service, $1.account) }
}

func deleteKeychainItems(_ items: [KeychainItemReference], store: any CredentialWriting) async -> [String] {
    var lines: [String] = []
    for item in items {
        do {
            try await store.delete(service: item.service, account: item.account)
            lines.append("Deleted Keychain item \(item.service) / \(item.account).")
        } catch {
            lines.append("Could not delete Keychain item \(item.service) / \(item.account): \(error)")
        }
    }
    return lines
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
