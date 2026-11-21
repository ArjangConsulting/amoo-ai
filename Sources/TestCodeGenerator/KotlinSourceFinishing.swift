import Foundation

/// Final passes over a generated Kotlin test file.
enum KotlinSourceFinishing {
    /// Drops every `import a.b.Name` whose `Name` the file never uses. Emitters list the imports any of
    /// their statements could need; a test whose source set lacks one of those libraries (no
    /// espresso-core in a Compose-only `androidTest`) must not fail to compile over an import it does
    /// not use. Wildcard imports are kept.
    static func prunedImports(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
        let kept = lines.filter { line in
            guard line.hasPrefix("import ") else { return true }
            let path = line.dropFirst("import ".count).split(separator: " ").first.map(String.init) ?? ""
            let name = line.components(separatedBy: " as ").last.flatMap { alias -> String? in
                line.contains(" as ") ? alias.trimmingCharacters(in: .whitespaces) : nil
            } ?? path.split(separator: ".").last.map(String.init) ?? ""
            guard name != "*", !name.isEmpty else { return true }
            return body.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression)
                != nil
        }
        return kept.joined(separator: "\n")
    }

    /// Sorts the import block the way ktlint's default `import-ordering` does: plain imports in ASCII
    /// order, then `java`, `javax` and `kotlin`, then aliased imports, with no blank lines between them.
    /// Emitters concatenate fixed, body-driven and context imports, which would otherwise interleave.
    static func sortedImports(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.firstIndex(where: { $0.hasPrefix("import ") }),
              let last = lines.lastIndex(where: { $0.hasPrefix("import ") })
        else { return source }
        let block = lines[first ... last]
        guard block.allSatisfy({ $0.hasPrefix("import ") || $0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return source }
        let imports = Array(Set(block.filter { $0.hasPrefix("import ") })).sorted { lhs, rhs in
            let left = importRank(lhs)
            let right = importRank(rhs)
            return left == right ? lhs < rhs : left < right
        }
        return (lines[..<first] + imports + lines[(last + 1)...]).joined(separator: "\n")
    }

    private static func importRank(_ line: String) -> Int {
        if line.contains(" as ") {
            return 2
        }
        let path = line.dropFirst("import ".count)
        return ["java.", "javax.", "kotlin."].contains { path.hasPrefix($0) } ? 1 : 0
    }

    /// Removes a wait for a node that the statement just before it already found or asserted: the
    /// recorder pairs every step with a readiness wait, so consecutive steps on one node repeated it.
    static func withoutRepeatedWaits(_ lines: [String]) -> [String] {
        var result: [String] = []
        var lastMatcher: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let matcher = waitMatcher(trimmed) {
                if matcher == lastMatcher {
                    continue
                }
                lastMatcher = matcher
            } else if let matcher = nodeMatcher(trimmed) {
                lastMatcher = matcher
            } else if !trimmed.isEmpty {
                lastMatcher = nil
            }
            result.append(line)
        }
        return result
    }

    /// The matcher of `composeTestRule.waitUntil(…) { composeTestRule.onAllNodes(M)….isNotEmpty() }`.
    private static func waitMatcher(_ line: String) -> String? {
        guard line.hasPrefix("composeTestRule.waitUntil("), line.hasSuffix(".fetchSemanticsNodes().isNotEmpty() }"),
              let start = line.range(of: "composeTestRule.onAllNodes("),
              let end = line.range(of: ").fetchSemanticsNodes().isNotEmpty() }", options: .backwards)
        else { return nil }
        return String(line[start.upperBound ..< end.lowerBound])
    }

    /// The matcher of `composeTestRule.onNode(M).…`, which leaves the node found.
    private static func nodeMatcher(_ line: String) -> String? {
        guard line.hasPrefix("composeTestRule.onNode("),
              let end = line.range(of: ").assertIsDisplayed()") ?? line.range(of: ").assertExists()")
        else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: "composeTestRule.onNode(".count) ..< end.lowerBound])
    }
}
