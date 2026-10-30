import Foundation
import StudioProtocol

/// `amoo config validate [--path <file>] [--json]`: checks the project's `amoo.config.json`
/// without resolving any credential, so it never touches the keychain or prints a value.
func handleConfigCommand(
    remaining: [String],
    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderConfigHelp(), exitCode: 0)
    }
    guard remaining.first == "validate" else {
        return CLIResult(output: renderConfigHelp(), exitCode: 64)
    }
    var path: String?
    var json = false
    var arguments = Array(remaining.dropFirst())[...]
    while let argument = arguments.popFirst() {
        switch argument {
        case "--path":
            guard let value = arguments.popFirst() else {
                return CLIResult(output: renderConfigHelp(), exitCode: 64)
            }
            path = value
        case "--json":
            json = true
        default:
            return CLIResult(output: renderConfigHelp(), exitCode: 64)
        }
    }
    let files = path.map { [URL(fileURLWithPath: $0, relativeTo: currentDirectory)] }
        ?? AmooProjectConfig.discoverAll(from: currentDirectory)
    guard let file = files.first else {
        return configResult(
            ok: false,
            message: "No \(AmooProjectConfig.fileName) found from \(currentDirectory.path) up to the repository root.",
            profiles: [],
            json: json
        )
    }
    do {
        let config = try AmooProjectConfig.load(layers: files)
        let summary = config.profiles.keys.sorted().map { name in
            let profile = config.profiles[name]
            let fields = profile?.fields.keys.sorted().joined(separator: ", ") ?? ""
            return "\(name): apps \(profile?.apps.joined(separator: ", ") ?? ""); fields \(fields)"
        }
        let message = files.count > 1
            ? "\(files.map(\.path).joined(separator: ", ")) are valid; \(file.path) wins."
            : "\(file.path) is valid."
        return configResult(ok: true, message: message, profiles: summary, json: json)
    } catch {
        return configResult(ok: false, message: "\(error)", profiles: [], json: json)
    }
}

private func configResult(ok: Bool, message: String, profiles: [String], json: Bool) -> CLIResult {
    let output: String
    if json {
        let object: [String: Any] = ["ok": ok, "message": message, "profiles": profiles]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        output = String(bytes: data, encoding: .utf8) ?? "{}"
    } else {
        output = ([message] + profiles.map { "  \($0)" }).joined(separator: "\n")
    }
    return CLIResult(output: output, exitCode: ok ? 0 : 1)
}

func renderConfigHelp() -> String {
    """
    Usage: amoo config validate [--path <file>] [--json]

    Checks amoo.config.json, the checked-in file of sign-in credential profiles. Without --path it
    is found by walking up from the current directory to the repository root. Validation never
    reads the keychain and never prints a credential value.

    An agent signs in with credential="<profile>#<field>" on fill_field, set_text or type_text;
    amoo types the value and never returns it. Example, at the repository root:

      {
        "version": 1,
        "profiles": {
          "mock-user": {
            "apps": ["com.example.app.qa"],
            "requires_launch_env": { "AUTH_EMULATOR_HOST": "*" },
            "fields": {
              "email":    { "literal": "qa@example.test", "class": "identifier" },
              "password": { "literal": "any-password",    "class": "secret" }
            }
          }
        }
      }

    apps limits where a profile may be typed; requires_launch_env must match the launch environment
    amoo sent the app ("*" = present). A secret only fills a secure field. Literal values are for
    mock accounts only; a real account uses {"keychain": {"service": …, "account": …}} instead.
    `amoo credentials add` writes either kind for you. See docs/credentials.md.

    Exit codes: 0 valid, 1 missing or invalid, 64 usage error.
    """
}
