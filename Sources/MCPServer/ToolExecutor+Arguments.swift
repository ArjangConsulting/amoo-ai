import AmooCore

// Optional arguments shared by several tools, parsed once so every tool rejects bad input the same way.

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
}
