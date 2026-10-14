import Foundation

/// A terminal conversation shared by the guided commands (`init`, `agent install`). Every method
/// returns nil at end of input, which callers treat as "the user walked away" and cancel.
protocol CLIPrompting {
    func say(_ text: String)
    func ask(_ prompt: String, default defaultValue: String?) -> String?
    func confirm(_ prompt: String, default defaultAnswer: Bool) -> Bool?
    func choose(_ prompt: String, options: [String], default index: Int) -> Int?
    func chooseMany(_ prompt: String, options: [String], defaults: [Int]) -> [Int]?
}

/// Parses `1,3`, `2-4`, `all` into sorted unique 0-based indexes; nil when anything is out of range.
func parseSelection(_ text: String, count: Int) -> [Int]? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed == "all" {
        return Array(0 ..< count)
    }
    var picked = Set<Int>()
    for part in trimmed.split(whereSeparator: { $0 == "," || $0 == " " }) {
        let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
        switch bounds.count {
        case 1:
            guard let value = bounds[0], (1 ... count).contains(value) else { return nil }
            picked.insert(value - 1)
        case 2:
            guard let low = bounds[0], let high = bounds[1], low <= high, low >= 1, high <= count else { return nil }
            picked.formUnion((low - 1) ... (high - 1))
        default:
            return nil
        }
    }
    return picked.isEmpty ? nil : picked.sorted()
}

struct StdioPrompter: CLIPrompting {
    func say(_ text: String) {
        print(text)
    }

    func ask(_ prompt: String, default defaultValue: String?) -> String? {
        print("\(prompt)\(defaultValue.map { " [\($0)]" } ?? ""): ", terminator: "")
        fflush(nil)
        guard let line = readLine() else { return nil }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer.isEmpty ? (defaultValue ?? "") : answer
    }

    func confirm(_ prompt: String, default defaultAnswer: Bool) -> Bool? {
        while true {
            print("\(prompt) [\(defaultAnswer ? "Y/n" : "y/N")]: ", terminator: "")
            fflush(nil)
            guard let line = readLine() else { return nil }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "": return defaultAnswer
            case "y", "yes": return true
            case "n", "no": return false
            default: print("Please answer y or n.")
            }
        }
    }

    func choose(_ prompt: String, options: [String], default index: Int) -> Int? {
        print("\(prompt):")
        for (offset, option) in options.enumerated() {
            print("  \(offset + 1)) \(option)")
        }
        while true {
            print("Choose [1-\(options.count)] [\(index + 1)]: ", terminator: "")
            fflush(nil)
            guard let line = readLine() else { return nil }
            let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return index
            }
            if let value = Int(answer), (1 ... options.count).contains(value) {
                return value - 1
            }
            print("Enter a number between 1 and \(options.count).")
        }
    }

    func chooseMany(_ prompt: String, options: [String], defaults: [Int]) -> [Int]? {
        print("\(prompt):")
        for (offset, option) in options.enumerated() {
            print("  \(offset + 1)) \(option)")
        }
        let fallback = defaults.map { String($0 + 1) }.joined(separator: ",")
        while true {
            print("Choose one or more (e.g. 1,3 or 1-2 or all) [\(fallback)]: ", terminator: "")
            fflush(nil)
            guard let line = readLine() else { return nil }
            let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                return defaults
            }
            if let picked = parseSelection(answer, count: options.count) {
                return picked
            }
            print("Enter numbers between 1 and \(options.count).")
        }
    }
}
