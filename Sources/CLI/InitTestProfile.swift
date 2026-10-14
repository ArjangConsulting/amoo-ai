import Foundation
import StudioProtocol

// swiftlint:disable multiline_arguments

// The Markdown template is a single linear document.
// Discovers evidence from checked-in Swift tests without modifying the receiving test target.
// swiftlint:disable:next function_body_length
func saveInitTestProfile(at root: URL) throws {
    let output = root.appendingPathComponent("amoo.md")
    // Profiles are repository-owned after discovery; never overwrite reviewed bindings on re-init.
    guard !FileManager.default.fileExists(atPath: output.path) else { return }
    let sources = discoverTestSources(root)
    let tests = sources.filter { $0.text.contains("XCUIApplication") || $0.text.contains("UITestCase") }
    let combined = tests.map(\.text).joined(separator: "\n")
    let bases = profileMatches(#"class\s+\w+\s*:\s*(\w+UITestCase)"#, in: combined)
    let preferredBases = Set(bases.filter { !$0.contains("Generated") })
    let base = preferredBases.count == 1 ? preferredBases.first : nil
    let baseSource = base
        .flatMap { name in
            sources.first { $0.text.contains("class \(name):") || $0.text.contains("class \(name) :") }?.text
        }
    let ownsApp = baseSource.map { !profileMatches(#"\b(?:var|let)\s+(app)\b"#, in: $0).isEmpty } ?? false
    let launches = baseSource?.contains("app.launch()") ?? false
    let imports = Set(profileMatches(#"(?m)^import\s+(\w+)"#, in: combined)).subtracting(["XCTest"])
    let timeoutConstants = Set(profileMatches(
        #"timeout\s*:\s*TimeInterval\s*=\s*(\w*Constants\.\w+)"#, in: combined
    ))
    let timeoutExpressions = timeoutConstants.count == 1 ? ["default": timeoutConstants.first!] : [:]
    let selectors = discoverProfileIdentifiers(in: sources.map(\.text))
    let waits = discoverProfileWaits(in: combined)
    let targets = Set(tests
        .flatMap { $0.path.split(separator: "/").filter { $0.hasSuffix("UITests") }.map(String.init) })
    let snippets = tests.flatMap { file in
        file.text.split(separator: "\n").enumerated().compactMap { index, line -> String? in
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
            return "- `\(file.path):\(index + 1)`: `\(line.trimmingCharacters(in: .whitespaces))`"
        }
    }.prefix(40).joined(separator: "\n")
    let context = StudioTestContext(
        imports: imports.sorted(), baseClass: base, harnessLaunchesApp: launches,
        selectorExpressions: selectors,
        idLookupTemplate: combined.contains("app.element(id:") ? "app.element(id: {{id}})" : nil,
        harnessOwnsApp: ownsApp,
        factoryOverride: baseSource?.contains("func makeApplication()") == true ? "super.makeApplication()" : nil,
        waitBindings: waits,
        timeoutExpressions: timeoutExpressions,
        relaunchHelper: combined.contains("func relaunchApplication(") ? "relaunchApplication()" : nil,
        targetPlatform: .ios
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try String(bytes: encoder.encode(context), encoding: .utf8)!
    let evidence = tests.map { "- `\($0.path)`" }.joined(separator: "\n")
    let document = """
    # Amoo repository integration

    Discovered by `amoo init`. Review the evidence and complete the bindings before export.
    Init creates no test files, adapter base class, or Generated directory.

    ## Test conventions

    - Framework: \(tests.isEmpty ? "not discovered; review required" : "Swift XCTest/XCUITest")
    - Base class: \(base ?? "not uniquely discovered; review required")
    - Application property owned by harness: \(ownsApp)
    - Application launched by harness: \(launches)
    - Target directory: \(targets.count == 1 ? targets.first! : "not uniquely discovered; review project configuration")
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

private struct TestProfileSource {
    let path: String
    let text: String
}

private func discoverTestSources(_ root: URL) -> [TestProfileSource] {
    let excluded: Set = [".git", ".build", ".build-linux", "build", "DerivedData", "Pods", "node_modules", ".swiftpm"]
    guard let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return [] }
    var sources: [TestProfileSource] = []
    for case let file as URL in enumerator {
        if excluded.contains(file.lastPathComponent) {
            enumerator.skipDescendants(); continue
        }
        guard file.pathExtension == "swift", let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        sources.append(TestProfileSource(path: String(file.path.dropFirst(root.path.count + 1)), text: text))
    }
    return sources.sorted { $0.path < $1.path }
}

// swiftlint:enable multiline_arguments
