import AmooCore
import Foundation
import MobileProject
import StudioProtocol

// swiftlint:disable multiline_arguments

// The Markdown template is a single linear document.
// Discovers evidence from checked-in Swift tests (parsed with SwiftSyntax by MobileProject) without
// modifying the receiving test target.
// swiftlint:disable:next function_body_length
func saveInitTestProfile(at root: URL, platform: Platform? = nil) throws {
    let output = root.appendingPathComponent("amoo.md")
    // Existing platform sections are repository-owned; only append newly discovered platforms.
    let facts = inspectInitHarness(at: root)
    let android = AndroidTestProfile.discover(at: root)
    let tests = facts.uiTestFiles
    let base = facts.baseClass?.value
    let project = discoverInitProjectFacts(root: root, testFiles: tests, baseClass: base)
    let ownsApp = facts.harnessOwnsApplication?.value ?? false
    let launches = facts.harnessLaunchesApplication?.value ?? false
    let timeoutExpressions = facts.defaultTimeout.map { ["default": $0.value] } ?? [:]
    // Only the wait helpers generated tests call are bound.
    let waits = facts.waitHelpers
        .filter { ["waitForExistence", "waitForHittability", "waitForAbsence"].contains($0.key) }
        .mapValues(\.template)
    let targets = facts.testDirectories
    let targetPlatform: Platform? = tests.isEmpty ? (android.files.isEmpty ? platform : .android) : .ios
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
        targetPlatform: targetPlatform,
        launchArguments: project.launchArguments
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
    - Initial state: confirm automation flags, onboarding behavior, and reset rules from existing tests.
    - Onboarding tests: confirm how existing tests enter onboarding.
    - Persistence tests: confirm when state resets and which relaunch helper preserves it.
    - Label selectors: confirm the required language/locale and existing launch helpers.
    - Calendar selectors: use the calendar identifier catalog and relative date helpers (today,
      previous month); do not substitute a recording's literal date for relative scenario intent.
    - Keep recordings, plans, and provenance outside test source directories. Create Swift files
      only when generation is requested. Compile and run exports in the real target.

    \(project.markdown())

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
    let androidDocument = android.files.isEmpty ? "" : try android.document()
    let combined = tests.isEmpty && !android.files.isEmpty
        ? "# Amoo repository integration\n\nDiscovered by amoo init. Review bindings before export.\n" + androidDocument
        : document + androidDocument
    if FileManager.default.fileExists(atPath: output.path) {
        // Preserve prose-only or malformed reviewed profiles for the owner to resolve.
        let ios: StudioTestContext?
        let existingAndroid: StudioTestContext?
        do {
            ios = try RepositoryTestProfile.discover(from: root, platform: .ios)
            existingAndroid = try RepositoryTestProfile.discover(from: root, platform: .android)
        } catch { return }
        let additions = (ios == nil && !tests.isEmpty ? "\n" + document : "")
            + (existingAndroid == nil ? androidDocument : "")
        guard !additions.isEmpty else { return }
        let existing = try String(contentsOf: output, encoding: .utf8)
        try (existing + "\n" + additions).write(to: output, atomically: true, encoding: .utf8)
    } else {
        try combined.write(to: output, atomically: true, encoding: .utf8)
    }
}

// swiftlint:enable multiline_arguments
