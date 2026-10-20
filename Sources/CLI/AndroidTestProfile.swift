import Foundation
import StudioProtocol

// swiftlint:disable multiline_arguments

/// Conservative source discovery: records Kotlin/Java instrumentation evidence without executing builds.
struct AndroidTestProfile {
    var files: [String] = []
    var evidence: [String] = []
    var frameworks: Set<String> = []
    var baseClasses: Set<String> = []
    private var sources: [String] = []

    static func discover(at root: URL) -> Self {
        var result = Self()
        let excluded: Set = ["build", ".gradle", ".git", ".build", "node_modules", "Pods", ".idea"]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return result }
        while let file = enumerator.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            else { continue }
            if values.isSymbolicLink == true || excluded.contains(file.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory != true, ["kt", "java"].contains(file.pathExtension),
                  (values.fileSize ?? 0) <= 1_048_576,
                  file.pathComponents.contains(where: { $0 == "androidTest" || $0 == "androidInstrumentedTest" }),
                  let source = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            result.inspect(source, path: relative)
        }
        result.files.sort()
        result.evidence = Array(result.evidence.sorted().prefix(200))
        return result
    }

    private mutating func inspect(_ source: String, path: String) {
        // Strip comments before identifying declarations/imports. Evidence remains verbatim for review.
        let code = source.replacingOccurrences(
            of: #"(?s)/\*.*?\*/|(?m)^\s*//[^\n]*"#,
            with: "",
            options: .regularExpression
        )
        guard code.contains("org.junit") || code.contains("androidx.test") || code.contains("androidx.compose.ui.test")
        else { return }
        files.append(path)
        sources.append(code)
        if code.contains("androidx.test.espresso") {
            frameworks.insert("Espresso")
        }
        if code.contains("androidx.compose.ui.test") {
            frameworks.insert("Jetpack Compose")
        }
        if code.contains("androidx.test.uiautomator") {
            frameworks.insert("UI Automator")
        }
        frameworks.insert("JUnit instrumentation")
        let patterns = [
            #"class\s+\w+\s*:\s*([\w.]+)\s*\("#,
            #"class\s+\w+\s+extends\s+([\w.]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                if let range = Range(match.range(at: 1), in: code) {
                    baseClasses.insert(String(code[range]))
                }
            }
        }
        let tokens = [
            "package ", "import ", "class ", "@Rule", "@get:Rule", "@Before", "@After",
            "ActivityScenario", "createAndroidComposeRule", "createComposeRule", "createEmptyComposeRule",
            "fun ", "void ", "const val ", "static final ", "testTag(", "withId(", "onNodeWithTag(",
            "launch(", "launchActivity", "clearPackageData", "Locale", "timeout"
        ]
        var excerptCount = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            guard tokens.contains(where: line.contains), excerptCount < 40 else { continue }
            excerptCount += 1
            evidence.append("- `\(path)` (source excerpt): `\(line.trimmingCharacters(in: .whitespaces).prefix(300))`")
        }
    }

    /// Bind only a uniquely declared, no-argument base with no competing lifecycle or test rules.
    private var discoveredBaseClass: String? {
        guard baseClasses.count == 1, let name = baseClasses.first else { return nil }
        let simple = name.components(separatedBy: ".").last ?? name
        let declaration = #"(?m)^\s*(?:public\s+)?(?:abstract|open)\s+class\s+"#
            + NSRegularExpression.escapedPattern(for: simple) + #"(?:\s*\(\s*\))?\s*(?:\{|$)"#
        let definitions = sources.filter { $0.range(of: declaration, options: .regularExpression) != nil }
        guard definitions.count == 1, let source = definitions.first,
              !["@Before", "@After", "@Rule", "@get:Rule", "launch(", "launchActivity", "createCompose"]
                  .contains(where: source.contains),
              let regex = try? NSRegularExpression(pattern: #"(?m)^\s*package\s+([\w.]+)"#),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        return "\(source[range]).\(simple)()"
    }

    func document() throws -> String {
        let context = StudioTestContext(baseClass: discoveredBaseClass, targetPlatform: .android)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let json = try String(bytes: encoder.encode(context), encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let modules = Set(files.compactMap { $0.components(separatedBy: "/src/").first }).sorted()
        return """

        ## Android test conventions

        - Frameworks: \(frameworks.sorted().joined(separator: ", "))
        - Source sets: \(modules.joined(separator: ", "))
        - Observed base classes: \(baseClasses.isEmpty ? "none" : baseClasses.sorted().joined(separator: ", "))
        - Review the imports, inherited rules, launch/reset behavior, helper signatures, IDs and timeouts below.
        - Kotlin baseClass bindings include constructor syntax, e.g. com.example.BaseUiTest().
        - Do not bind an inherited ActivityScenarioRule or Compose rule to a standalone generated launch.
          Compose exports own their composeTestRule; choose a base without a competing rule.
        - Source evidence is not an automatically callable helper contract. Bind only helpers that match
          the recorded operation and whose imports are accessible to the generated test.
        - Use --ui-toolkit compose for Compose exports, or view for Espresso exports.

        ### Android source evidence

        \(files.map { "- `\($0)`" }.joined(separator: "\n"))

        \(evidence.joined(separator: "\n"))

        ### Android export bindings

        \(RepositoryTestProfile.contextFence)\(json)
        ```

        """
    }
}

// swiftlint:enable multiline_arguments
