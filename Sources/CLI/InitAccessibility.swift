import Foundation
import StudioProtocol
import SwiftyTerminal

private typealias Check = AccessibilityCheckPolicy.Check
private typealias Configuration = AccessibilityCheckPolicy.Configuration

/// Parses `--accessibility-checks` / `--accessibility-configurations`: a comma list, `all`, or `none`.
func parseInitAccessibilityList<Item: RawRepresentable & CaseIterable>(
    _ raw: String,
    flag: String,
    as _: Item.Type
) throws -> [Item] where Item.RawValue == String {
    let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    if names == ["all"] {
        return Array(Item.allCases)
    }
    if names == ["none"] {
        return []
    }
    return try names.map { name in
        guard let item = Item(rawValue: name) else {
            let accepted = Item.allCases.map(\.rawValue).joined(separator: ", ")
            throw EnvCommandParseError.usage("\(flag) has no entry '\(name)'; use all, none, or: \(accepted).")
        }
        return item
    }
}

/// The project's accessibility checks with any `--accessibility-*` flags applied, or nil without one.
func initAccessibilityPolicy(_ request: InitRequest, current: AccessibilityCheckPolicy) -> AccessibilityCheckPolicy? {
    guard request.accessibilityChecks != nil || request.accessibilityConfigurations != nil else { return nil }
    return AccessibilityCheckPolicy(
        checks: request.accessibilityChecks ?? current.enabledChecks,
        configurations: request.accessibilityConfigurations ?? current.enabledConfigurations
    )
}

/// Applies `--accessibility-*` flags, or asks in a guided run without `--yes`, and saves a changed
/// choice. Output follows `settleInitScreenshots`: said now when guided, returned when headless.
func settleInitAccessibility(
    _ request: InitRequest,
    interactive: Bool,
    root: URL,
    prompter: any Prompting
) -> String? {
    let resolution = AccessibilityCheckResolution.resolve(from: root)
    if case let .invalid(problem) = resolution {
        let note = "Accessibility checks not changed: \(problem)"
        if interactive {
            prompter.say(note)
            return nil
        }
        return request.json ? nil : note
    }
    let current = resolution.policy
    let flagged = initAccessibilityPolicy(request, current: current)
    let asked = interactive && !request.assumeYes && flagged == nil
    guard let chosen = asked ? askInitAccessibilityPolicy(current: current, prompter: prompter) : flagged,
          let note = applyInitAccessibilityPolicy(chosen, current: resolution, root: root) else { return nil }
    if interactive {
        prompter.say(note)
        return nil
    }
    return request.json ? nil : note
}

/// Asks which checks to run on each screen and which configurations to repeat them in. Nothing is
/// pre-selected for a project that has not opted in: every accessibility check is opt-in.
func askInitAccessibilityPolicy(
    current: AccessibilityCheckPolicy,
    prompter: any Prompting
) -> AccessibilityCheckPolicy {
    prompter.say("""

    Accessibility checks
    Choose what `check_accessibility` evaluates on a screen. Nothing runs unless you pick it here;
    an agent can still leave a check or a flagged element out of one call.
    """)
    let checks = Check.allCases
    let chosenChecks = prompter.chooseMany(
        "Checks to run on each screen (none selected means accessibility is not checked)",
        options: checks.map { "\($0.rawValue): \($0.summary)" },
        defaults: checks.indices.filter { current.enabledChecks.contains(checks[$0]) }
    ).map { $0.map { checks[$0] } } ?? current.enabledChecks
    guard !chosenChecks.isEmpty else {
        return AccessibilityCheckPolicy(checks: [], configurations: [])
    }
    let configurations = Configuration.allCases
    let chosenConfigurations = prompter.chooseMany(
        "Also repeat the checks in",
        options: configurations.map { "\($0.rawValue): \($0.summary)" },
        defaults: configurations.indices.filter { current.enabledConfigurations.contains(configurations[$0]) }
    ).map { $0.map { configurations[$0] } } ?? current.enabledConfigurations
    return AccessibilityCheckPolicy(checks: chosenChecks, configurations: chosenConfigurations)
}

/// Writes `policy` when it differs from what is in effect, and describes the outcome. Declining every
/// check in a project that never opted in writes nothing, so a config is not created just to say "no".
func applyInitAccessibilityPolicy(
    _ policy: AccessibilityCheckPolicy,
    current: AccessibilityCheckResolution,
    root: URL
) -> String? {
    let unchanged = policy.enabledChecks == current.policy.enabledChecks
        && policy.enabledConfigurations == current.policy.enabledConfigurations
    if unchanged || (current == .notConfigured && policy.enabledChecks.isEmpty) {
        return nil
    }
    let file = AmooProjectConfig.discover(from: root) ?? AmooProjectConfig.defaultLocation(from: root)
    do {
        try AmooProjectConfig.writeAccessibilityChecks(policy, to: file)
        return "Saved accessibility checks (\(describeAccessibilityPolicy(policy))) to \(file.path)."
    } catch {
        return "Accessibility checks not saved to \(file.path): \(error)"
    }
}

func describeAccessibilityPolicy(_ policy: AccessibilityCheckPolicy) -> String {
    guard !policy.enabledChecks.isEmpty else { return "none opted in" }
    let checks = policy.enabledChecks.map(\.rawValue).joined(separator: ", ")
    let configurations = policy.enabledConfigurations.map(\.rawValue).joined(separator: ", ")
    return checks + (configurations.isEmpty ? "" : "; repeated in \(configurations)")
}

/// The line in the managed `## amoo init` block, so agents know which checks to run on each screen.
func accessibilityAgentsLine(_ resolution: AccessibilityCheckResolution) -> String? {
    guard case let .configured(policy) = resolution, !policy.enabledChecks.isEmpty else { return nil }
    return "- Accessibility: run `check_accessibility` on each screen you verify"
        + " (\(describeAccessibilityPolicy(policy)), set in `\(AmooProjectConfig.fileName)`; `amoo init` to change)."
        + " Use exclude_checks/exclude_elements with exclude_reason for a false positive."
}
