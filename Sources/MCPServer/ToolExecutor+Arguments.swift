import AmooCore

// Optional arguments shared by several tools, parsed once so every tool rejects bad input the same way.

/// Which of several matches an `index` / `first` argument chose.
enum ElementPick: Equatable {
    /// `first: true`, emitted as `.firstMatch` in generated XCUITest code.
    case first
    /// `index: n` (0-based), emitted as `.element(boundBy: n)`.
    case index(Int)

    /// Reads the optional `index` and `first` arguments shared by the selector-taking tools.
    /// `index` and `first` together are rejected, since each would pick differently.
    static func parse(_ arguments: [String: String]) throws -> Self? {
        let first = arguments["first"].flatMap { value -> Bool? in
            switch value.lowercased() {
            case "true", "1", "yes": true
            case "false", "0", "no": false
            default: nil
            }
        }
        if let raw = arguments["first"], first == nil {
            throw ToolExecutionError(code: "invalid_argument", message: "first must be true or false, got '\(raw)'.")
        }
        let index = try arguments["index"].map { raw -> Int in
            guard let value = Int(raw), value >= 0 else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "index must be a whole number 0 or greater (0-based), got '\(raw)'."
                )
            }
            return value
        }
        switch (index, first) {
        case (.some, true?):
            throw ToolExecutionError(
                code: "invalid_argument", message: "Pass either index or first, not both."
            )
        case let (index?, _): return .index(index)
        case (nil, true?): return .first
        default: return nil
        }
    }
}

/// A `start_session` `port` that is not a usable TCP port.
struct InvalidCompanionPortError: Error, CustomStringConvertible {
    static let allowed = 1024 ... 65535
    let raw: String

    var description: String {
        let range = "\(Self.allowed.lowerBound) and \(Self.allowed.upperBound)"
        return "port must be a whole number between \(range), got '\(raw)'."
    }
}

extension DriverToolExecutor {
    /// The optional `port` argument of `start_session`; `nil` when absent or empty.
    nonisolated static func parseCompanionPort(_ raw: String?) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let port = Int(raw), InvalidCompanionPortError.allowed.contains(port) else {
            throw InvalidCompanionPortError(raw: raw)
        }
        return port
    }

    /// Narrows `elements` to the one `pick` names, or requires a unique match when there is no pick.
    ///
    /// Duplicates are common — iPadOS 27's top tab bar exposes each tab twice with an identical id,
    /// label and frame — and `uniqueElement` alone leaves no way to proceed short of raw
    /// coordinates. The pick indexes the selector's matches in the order the device reports them,
    /// which is the order XCUITest's `element(boundBy:)` uses in the generated test.
    ///
    /// - Parameter missingIsNil: an `index` past the last match returns `nil` instead of throwing,
    ///   for callers where "nothing there" is a valid answer (`assert_absent`, `find_elements`).
    func pickElement(
        _ elements: [ElementInfo],
        pick: ElementPick?,
        missingIsNil: Bool = false
    ) throws -> ElementInfo? {
        guard let pick else { return try uniqueElement(elements) }
        switch pick {
        case .first:
            return elements.first
        case let .index(index):
            if index < elements.count {
                return elements[index]
            }
            if missingIsNil || elements.isEmpty {
                return nil
            }
            throw ToolExecutionError(
                code: "index_out_of_range",
                message: "index \(index) is out of range: the selector matched \(elements.count) element(s)"
                    + " (valid indexes 0...\(elements.count - 1))."
            )
        }
    }
}
