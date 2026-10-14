import Foundation
import MobileProject
import StudioProtocol

// swiftlint:disable multiline_arguments

// The Markdown template is a single linear document.
// Discovers evidence from checked-in Swift tests (parsed with SwiftSyntax by MobileProject) without
// modifying the receiving test target.
// swiftlint:disable:next function_body_length
func saveInitTestProfile(at root: URL) throws {
    let output = root.appendingPathComponent("amoo.md")
    // Profiles are repository-owned after discovery; never overwrite reviewed bindings on re-init.
    guard !FileManager.default.fileExists(atPath: output.path) else { return }
    let facts = UITestHarnessInspector().inspect(root.path)
    let tests = facts.uiTestFiles
    let base = facts.baseClass?.value
    let ownsApp = facts.harnessOwnsApplication?.value ?? false
    let launches = facts.harnessLaunchesApplication?.value ?? false
    let timeoutExpressions = facts.defaultTimeout.map { ["default": $0.value] } ?? [:]
    // Only the wait helpers generated tests call are bound.
    let waits = facts.waitHelpers
        .filter { ["waitForExistence", "waitForHittability", "waitForAbsence"].contains($0.key) }
        .mapValues(\.template)
    let targets = facts.testDirectories.compactMap { $0.split(separator: "/").last.map(String.init) }
    let snippets = tests.flatMap { path -> [String] in
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").enumerated().compactMap { index, line -> String? in
            let tokens = [
                "usingLanguage(",
                "makeApplication(",
                "relaunchApplication(",
                "UITestConstants.",
                "UITestCalendar.",
                "CalendarAccessibilityID.",
                "element(id:",
                "onboarding",
                "reset"
            ]
            guard tokens.contains(where: line.contains) else { return nil }
            return "- `\(path):\(index + 1)`: `\(line.trimmingCharacters(in: .whitespaces))`"
        }
    }.prefix(40).joined(separator: "\n")
    let context = StudioTestContext(
        imports: facts.imports, baseClass: base, harnessLaunchesApp: launches,
        selectorExpressions: facts.identifierCatalog,
        idLookupTemplate: facts.applicationExtensions.contains("element(id:)") ? "app.element(id: {{id}})" : nil,
        harnessOwnsApp: ownsApp,
        factoryOverride: facts.applicationFactory == nil ? nil : "super.makeApplication()",
        waitBindings: waits,
        timeoutExpressions: timeoutExpressions,
        relaunchHelper: facts.relaunchHelper?.template,
        targetPlatform: .ios
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let json = try String(bytes: encoder.encode(context), encoding: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    let evidence = (tests.map { "- `\($0)`" } + facts.diagnostics.map { "- Review: \($0)" }).joined(separator: "\n")
    let document = """
    # Amoo repository integration

    Discovered by `amoo init`. Review the evidence and complete the bindings before export.
    Init creates no test files, adapter base class, or Generated directory.

    ## Test conventions

    - Framework: \(tests.isEmpty ? "not discovered; review required" : "Swift XCTest/XCUITest")
    - Base class: \(base ?? "not uniquely discovered; review required")
    - Application property owned by harness: \(ownsApp)
    - Application launched by harness: \(launches)
    - Target directory: \(targets.count == 1 ? targets[0] : "not uniquely discovered; review project configuration")
    - Imports: retain only modules required by the exported scenario.
    - Identifier lookup: map recorded IDs to the repository catalog in selectorExpressions;
      set idLookupTemplate to the existing typed lookup (for example app.element(id: {{id}})).
    - Waits/assertions: fill waitBindings and assertionBindings with existing helper call templates.
    - Timing: fill timeoutExpressions with repository constants, keyed by milliseconds or default.
    - Factory: customize factoryOverride using the existing fluent launch helpers.

    ## Scenario launch and calendar rules

    Review these rules against the existing harness; discovery does not invent launch flags.
    - Ordinary tests: enable automation, bypass onboarding, reset state initially.
    - Onboarding tests: disable onboarding bypass.
    - Persistence tests: reset initially; preserve stored state using the repository relaunch helper.
    - Label selectors: pin English and en_US through existing launch helpers before setup launches.
    - Calendar selectors: use the calendar identifier catalog and relative date helpers (today,
      previous month); do not substitute a recording's literal date for relative scenario intent.
    - Keep recordings, plans, and provenance outside test source directories. Create Swift files
      only when generation is requested. Compile and run exports in the real target.

    ## Source evidence

    \(evidence.isEmpty ? "No Swift UI-test harness discovered. Complete the profile manually." : evidence)

    ## Observed conventions (review scenario applicability)

    \(snippets.isEmpty ? "No scenario-specific helper calls discovered." : snippets)

    ## Export bindings

    This fenced context is consumed automatically by recording and export, in memory.
    Explicit --context/context_json overrides it. Review ownership before enabling a custom harness.

    \(RepositoryTestProfile.contextFence)\(json)
    ```

    """
    try document.write(to: output, atomically: true, encoding: .utf8)
}

// swiftlint:enable multiline_arguments
