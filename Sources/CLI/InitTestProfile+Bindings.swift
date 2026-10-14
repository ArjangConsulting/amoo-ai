import Foundation

/// Only literal constants inside identifier enums are mapped; computed/dynamic IDs need review.
func discoverProfileIdentifiers(in sources: [String]) -> [String: String] {
    var candidates: [String: Set<String>] = [:]
    for source in sources {
        var depth = 0
        var enums: [(name: String, depth: Int)] = []
        for line in source.split(separator: "\n") {
            let text = String(line).components(separatedBy: "//")[0]
            if let name = profileMatches(#"\benum\s+(\w+)[^{]*\{"#, in: text).first {
                enums.append((name, depth + 1))
            }
            let path = enums.map(\.name)
            if path.first.map({ $0.hasSuffix("AutomationID") || $0.hasSuffix("AccessibilityID") }) == true,
               let regex =
               try? NSRegularExpression(pattern: #"\bstatic\s+let\s+(\w+)(?:\s*:\s*String)?\s*=\s*"([^"\\]*)""#) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let name = Range(match.range(at: 1), in: text),
                          let value = Range(match.range(at: 2), in: text) else { continue }
                    candidates[String(text[value]), default: []]
                        .insert((path + [String(text[name])]).joined(separator: "."))
                }
            }
            // Count structure without braces inside string literals.
            let structure = text.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "", options: .regularExpression)
            depth += structure.filter { $0 == "{" }.count - structure.filter { $0 == "}" }.count
            enums.removeAll { $0.depth > depth }
        }
    }
    return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
}

/// Existing single-element wait helpers with defaulted remaining parameters can be reused safely.
func discoverProfileWaits(in source: String) -> [String: String] {
    var bindings: [String: String] = [:]
    for name in ["waitForExistence", "waitForHittability", "waitForAbsence"] {
        guard !source.contains("private func \(name)"), !source.contains("fileprivate func \(name)") else { continue }
        let signatures = profileMatches("func \(name)\\s*\\(([^)]*)\\)", in: source)
        guard signatures.count == 1 else { continue }
        let parameters = signatures[0].split(separator: ",")
        guard let first = parameters.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("_ "),
              first.contains(": XCUIElement"), parameters.dropFirst().allSatisfy({ $0.contains("=") }) else { continue }
        bindings[name] = "\(name)({{element}})"
    }
    return bindings
}

func profileMatches(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}
