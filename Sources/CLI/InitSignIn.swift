import Foundation
import StudioProtocol

/// Whether the repository lets agents sign in by credential reference. `amoo init` reports it and
/// never writes `amoo.config.json` itself: accounts are the project's to declare.
enum InitSignInStatus: Equatable {
    case missing
    case invalid(path: String, problem: String)
    case configured(path: String, profiles: [String])

    static func inspect(root: URL) -> Self {
        let files = AmooProjectConfig.discoverAll(from: root)
        guard let file = files.first else { return .missing }
        do {
            let profiles = try AmooProjectConfig.load(layers: files).profiles.keys.sorted()
            return .configured(path: file.path, profiles: profiles)
        } catch let error as AmooProjectConfigError {
            return .invalid(path: file.path, problem: error.problem)
        } catch {
            return .invalid(path: file.path, problem: "\(error)")
        }
    }

    /// The line in the managed `## amoo init` block, so agents reading `AGENTS.md` know how to sign in.
    func agentsLine(relativeTo base: String) -> String {
        switch self {
        case .missing:
            "- Sign-in: no `\(AmooProjectConfig.fileName)`; signed-in flows report `blocked: no credentials`"
                + " until a person runs `amoo credentials add`."
        case let .invalid(path, _):
            "- Sign-in: `\(portableInitPath(path, relativeTo: base))` is invalid; run `amoo config validate`."
        case let .configured(path, _):
            "- Sign-in: profiles in `\(portableInitPath(path, relativeTo: base))`; pass"
                + " `credential=<profile>#<field>`, never a password. A person adds accounts with"
                + " `amoo credentials add`."
        }
    }

    /// The section of init's closing summary.
    var nextSteps: String {
        switch self {
        case .missing:
            return """

            Sign in during tests
            No sign-in account yet, so agents report `blocked: no credentials` for signed-in flows.
            Add one any time with `amoo credentials add`: a mock account is saved in
            \(AmooProjectConfig.fileName), a real one in your macOS Keychain. Agents never see the password.
            """
        case let .invalid(path, problem):
            return """

            Sign in during tests
            \(path) is invalid: \(problem)
            Fix it, then run `amoo config validate`.
            """
        case let .configured(_, profiles):
            let declared = profiles.isEmpty ? "no profiles" : profiles.joined(separator: ", ")
            return """

            Sign in during tests
            \(AmooProjectConfig.fileName) declares \(declared).
            Agents sign in with credential=<profile>#<field> and never see the value.
            Add or change accounts with `amoo credentials add`; `amoo credentials check` confirms Keychain access.
            """
        }
    }
}
