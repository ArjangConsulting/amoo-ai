import Foundation

/// What `amoo init --save` records about a repository beyond its UI-test harness, because recording
/// and export need it later and cannot recover it from a session:
///
/// - **launch configuration** — the language, locale and text-size flags the existing UI tests launch
///   with. Label selectors and selected-state labels depend on them, so a recording made under
///   another locale produces a test that fails elsewhere;
/// - **concurrency** — the UI-test target's Swift language mode and whether the harness base class is
///   main-actor isolated, which decides how the generated class is isolated;
/// - **app identifiers** — the product bundle ids of the non-test targets, which `start_session`
///   needs as `app_id`.
///
/// Everything here is read from checked-in source and project files. Discovery reports what it saw,
/// seeds structured launch flags only where the evidence is unambiguous, and leaves the rest as
/// reviewable evidence.
struct InitProjectFacts: Equatable {
    /// One literal launch flag found in a UI test, kept with where it was found.
    struct LaunchSite: Equatable {
        var path: String
        var line: Int
        var text: String
    }

    /// Locale and text-size flags every literal occurrence agrees on, in the order first seen.
    var launchArguments: [String] = []
    /// Environment keys are reported but never seeded: they are scenario or CI switches, not locale.
    var launchEnvironment: [String: String] = [:]
    /// Every launch site found, for the reviewer.
    var launchSites: [LaunchSite] = []
    /// Flags found with more than one literal value, or set through a variable. Not seeded.
    var undecidedFlags: [String] = []
    /// `SWIFT_VERSION` and `swift-tools-version` evidence, as `value (path)`.
    var swiftLanguageModes: [String] = []
    /// `SWIFT_STRICT_CONCURRENCY` / `SWIFT_DEFAULT_ACTOR_ISOLATION` evidence, as `NAME = value (path)`.
    var concurrencySettings: [String] = []
    /// Whether the harness base class is declared `@MainActor`; `nil` when it was not found.
    var baseClassMainActor: Bool?
    /// Non-test product bundle identifiers.
    var appIdentifiers: [String] = []
}

/// Flags that change what the app displays rather than what a scenario does. Only these are seeded.
private let seededLaunchFlags: Set<String> = [
    "-AppleLanguages", "-AppleLocale", "-UIPreferredContentSizeCategoryName", "-AppleTextDirection"
]

private let skippedDirectories: Set<String> = [
    ".build", "build", "DerivedData", "Pods", ".git", "node_modules", "SourcePackages", ".swiftpm",
    "xcuserdata", "Carthage"
]

/// Reads launch, concurrency and identifier facts under `root`.
///
/// - Parameters:
///   - testFiles: the UI-test sources, relative to `root`, as discovered by the harness inspector.
///   - baseClass: the harness base class name, when one was found.
func discoverInitProjectFacts(root: URL, testFiles: [String], baseClass: String?) -> InitProjectFacts {
    var facts = InitProjectFacts()
    var sources: [(path: String, text: String)] = []
    for path in testFiles {
        if let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) {
            sources.append((path, text))
        }
    }
    scanLaunchSites(in: sources, into: &facts)
    if let baseClass {
        facts.baseClassMainActor = baseClassIsMainActor(baseClass, in: sources)
    }
    scanProjectFiles(under: root, into: &facts)
    return facts
}

// MARK: - Launch configuration

// One linear scan over three source patterns; splitting it would only scatter the shared state.
// swiftlint:disable:next cyclomatic_complexity
private func scanLaunchSites(in sources: [(path: String, text: String)], into facts: inout InitProjectFacts) {
    var valuesByFlag: [String: [String]] = [:]
    var flagOrder: [String] = []
    var dynamicFlags: Set<String> = []

    let arrays =
        regex(#"launchArguments\s*(?:=|\+=)\s*\[([^\]]*)\]|launchArguments\.append\(contentsOf:\s*\[([^\]]*)\]"#)
    let singles = regex(#"launchArguments\.append\(\s*"((?:[^"\\]|\\.)*)"\s*\)"#)
    let environment = regex(#"launchEnvironment\[\s*"((?:[^"\\]|\\.)*)"\s*\]\s*=\s*"((?:[^"\\]|\\.)*)""#)

    for (path, text) in sources {
        let whole = NSRange(text.startIndex..., in: text)
        for match in arrays.matches(in: text, range: whole) {
            let group = (1 ... 2).map { match.range(at: $0) }.first { $0.location != NSNotFound } ?? match.range
            guard let range = Range(group, in: text) else { continue }
            let body = String(text[range])
            let elements = splitTopLevel(body)
            let tokens = elements.compactMap { stringLiteral($0) }
            record(path, text, match.range, into: &facts)
            if tokens.count != elements.count {
                // A variable among the elements: flag names it supplies cannot be read.
                for token in tokens where token.hasPrefix("-") {
                    dynamicFlags.insert(token)
                }
            }
            collect(tokens, into: &valuesByFlag, order: &flagOrder)
        }
        for match in singles.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            record(path, text, match.range, into: &facts)
            collect([String(text[range])], into: &valuesByFlag, order: &flagOrder)
        }
        for match in environment.matches(in: text, range: whole) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            record(path, text, match.range, into: &facts)
            facts.launchEnvironment[String(text[keyRange])] = String(text[valueRange])
        }
    }

    for flag in flagOrder where seededLaunchFlags.contains(flag) {
        let values = Set(valuesByFlag[flag] ?? [])
        if values.count == 1, !dynamicFlags.contains(flag), let value = valuesByFlag[flag]?.first, !value.isEmpty {
            facts.launchArguments += [flag, value]
        } else {
            facts.undecidedFlags.append(flag)
        }
    }
    facts.launchSites.sort { ($0.path, $0.line) < ($1.path, $1.line) }
}

private func record(_ path: String, _ text: String, _ range: NSRange, into facts: inout InitProjectFacts) {
    guard let swiftRange = Range(range, in: text) else { return }
    let line = text[..<swiftRange.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    let rendered = text[swiftRange].split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    let site = InitProjectFacts.LaunchSite(path: path, line: line, text: String(rendered.prefix(200)))
    if !facts.launchSites.contains(site) {
        facts.launchSites.append(site)
    }
}

/// Appends each `-flag value` pair; a trailing flag with no value is recorded with an empty value.
private func collect(_ tokens: [String], into values: inout [String: [String]], order: inout [String]) {
    var index = 0
    while index < tokens.count {
        let token = tokens[index]
        guard token.hasPrefix("-") else {
            index += 1
            continue
        }
        let value = index + 1 < tokens.count && !tokens[index + 1].hasPrefix("-") ? tokens[index + 1] : ""
        if values[token] == nil {
            order.append(token)
        }
        values[token, default: []].append(value)
        index += value.isEmpty ? 1 : 2
    }
}

/// Splits an array literal's body on commas outside string literals and brackets.
private func splitTopLevel(_ body: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var inString = false
    var escaped = false
    var depth = 0
    for character in body {
        if inString {
            current.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }
        switch character {
        case "\"":
            inString = true
            current.append(character)
        case "(", "[":
            depth += 1
            current.append(character)
        case ")", "]":
            depth -= 1
            current.append(character)
        case "," where depth == 0:
            parts.append(current)
            current = ""
        default:
            current.append(character)
        }
    }
    parts.append(current)
    return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

/// The contents of a plain string literal, or `nil` for anything else (a variable, an interpolation).
private func stringLiteral(_ element: String) -> String? {
    guard element.count >= 2, element.hasPrefix("\""), element.hasSuffix("\""),
          !element.contains("\\(") else { return nil }
    return String(element.dropFirst().dropLast())
}

// MARK: - Concurrency and identifiers

private func baseClassIsMainActor(_ name: String, in sources: [(path: String, text: String)]) -> Bool? {
    let declaration = regex(#"((?:@\w+\s+)*)(?:(?:open|public|internal|final|private|fileprivate)\s+)*class\s+"#
        + NSRegularExpression.escapedPattern(for: name) + #"\b"#)
    for (_, text) in sources {
        if let match = declaration.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return text[range].contains("@MainActor")
        }
    }
    return nil
}

// One walk that reads three kinds of project file; the per-file branches share its accumulators.
// swiftlint:disable:next cyclomatic_complexity
private func scanProjectFiles(under root: URL, into facts: inout InitProjectFacts) {
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return }
    let setting =
        regex(
            #"(SWIFT_VERSION|SWIFT_STRICT_CONCURRENCY|SWIFT_DEFAULT_ACTOR_ISOLATION)"?\s*[=:]\s*"?([A-Za-z0-9._]+)"?"#
        )
    let identifier = regex(#"PRODUCT_BUNDLE_IDENTIFIER"?\s*[=:]\s*"?([A-Za-z0-9._\-]+)"?"#)
    var modes = Set<String>()
    var settings = Set<String>()
    var identifiers = Set<String>()
    var visited = 0
    while let url = walker.nextObject() as? URL {
        visited += 1
        if visited > 50000 {
            break
        }
        let name = url.lastPathComponent
        if skippedDirectories.contains(name) {
            walker.skipDescendants()
            continue
        }
        guard ["project.pbxproj", "project.xcproj", "Package.swift"].contains(name),
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        // The enumerator may report a resolved path (`/private/var/…`) for a root given as `/var/…`.
        let base = root.resolvingSymlinksInPath().path + "/"
        let resolved = url.resolvingSymlinksInPath().path
        let relative = resolved.hasPrefix(base) ? String(resolved.dropFirst(base.count)) : resolved
        let whole = NSRange(text.startIndex..., in: text)
        if name == "Package.swift" {
            if let tools = firstGroup(regex(#"swift-tools-version:?\s*([0-9.]+)"#), in: text) {
                modes.insert("swift-tools-version \(tools) (\(relative))")
            }
            for match in regex(#"\.v([0-9]+)\b"#).matches(in: text, range: whole) {
                if let range = Range(match.range(at: 1), in: text), let first = text[range].first, first >= "4" {
                    modes.insert("language mode .v\(text[range]) (\(relative))")
                }
            }
            continue
        }
        for match in setting.matches(in: text, range: whole) {
            guard let key = Range(match.range(at: 1), in: text), let value = Range(match.range(at: 2), in: text) else {
                continue
            }
            if text[key] == "SWIFT_VERSION" {
                modes.insert("\(text[value]) (\(relative))")
            } else {
                settings.insert("\(text[key]) = \(text[value]) (\(relative))")
            }
        }
        for match in identifier.matches(in: text, range: whole) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range])
            // Test targets and unresolved variables are not apps `start_session` can launch.
            if !value.lowercased().contains("tests"), !value.contains("$") {
                identifiers.insert(value)
            }
        }
    }
    facts.swiftLanguageModes = modes.sorted()
    facts.concurrencySettings = settings.sorted()
    facts.appIdentifiers = identifiers.sorted()
}

private func firstGroup(_ expression: NSRegularExpression, in text: String) -> String? {
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

private func regex(_ pattern: String) -> NSRegularExpression {
    // The patterns are literals in this file; a failure is a programming error caught by the tests.
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
}

// MARK: - Rendering

extension InitProjectFacts {
    /// The `amoo.md` evidence sections: observed launch flags, concurrency, and app identifiers.
    func markdown() -> String {
        var sections: [String] = []

        var launch = ["## Launch configuration (observed)", ""]
        if launchSites.isEmpty {
            launch.append("No launch flags found in the discovered UI tests.")
        } else {
            launch.append("Seen in the existing UI tests; `start_session` applies `launchArguments` from the")
            launch.append("bindings below only when the caller passes none. Review before relying on them.")
            launch += launchSites.prefix(40).map { "- `\($0.path):\($0.line)`: `\($0.text)`" }
        }
        if !launchArguments.isEmpty {
            let seeded = launchArguments.joined(separator: " ")
            launch.append("- Seeded into the bindings (every literal occurrence agrees): `\(seeded)`")
        }
        if !undecidedFlags.isEmpty {
            let flags = undecidedFlags.map { "`\($0)`" }.joined(separator: ", ")
            launch.append("- Not seeded (values differ or are computed): \(flags)")
        }
        if !launchEnvironment.isEmpty {
            let pairs = launchEnvironment.sorted { $0.key < $1.key }.map { "`\($0.key)=\($0.value)`" }
            launch.append("- Environment set by tests (never seeded; pass scenario switches at `start_session`): "
                + pairs.joined(separator: ", "))
        }
        sections.append(launch.joined(separator: "\n"))

        var concurrency = ["## Concurrency", ""]
        concurrency.append("- Swift language mode: " + (swiftLanguageModes.isEmpty
                ? "not found; review the test target's build settings."
                : swiftLanguageModes.joined(separator: "; ")))
        if !concurrencySettings.isEmpty {
            concurrency.append("- Build settings: " + concurrencySettings.joined(separator: "; "))
        }
        switch baseClassMainActor {
        case true?:
            concurrency.append("- The harness base class is `@MainActor`; the generated class is too.")
        case false?:
            concurrency.append("- The harness base class is not main-actor isolated. The generated class is "
                + "`@MainActor` and does its setup and teardown in the async `setUp()` / `tearDown()` hooks.")
        case nil:
            concurrency.append("- Harness base class isolation: not determined; the generated class is `@MainActor`.")
        }
        sections.append(concurrency.joined(separator: "\n"))

        var identifiers = ["## App identifiers", ""]
        identifiers.append(appIdentifiers.isEmpty
            ? "No product bundle identifiers found; pass `app_id` to `start_session`."
            : "Candidate `app_id` values from the project (test targets excluded): "
            + appIdentifiers.map { "`\($0)`" }.joined(separator: ", "))
        sections.append(identifiers.joined(separator: "\n"))

        return sections.joined(separator: "\n\n")
    }
}
