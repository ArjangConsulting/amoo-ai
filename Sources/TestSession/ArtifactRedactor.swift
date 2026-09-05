import Foundation

/// Redacts known session secrets and sensitive launch metadata before artifact serialization.
/// Values explicitly marked as fixtures may be recorded; secret values stay in memory only.
public struct ArtifactRedactor: Sendable {
    private var secrets: Set<String> = []

    public init(environment: [String: String] = [:], arguments: [String] = []) {
        for (key, value) in environment where Self.isSensitiveKey(key) {
            register(value)
        }
        var sensitiveNext = false
        for argument in arguments {
            if sensitiveNext {
                register(argument)
            }
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            sensitiveNext = Self.isSensitiveKey(parts.first ?? "") && parts.count == 1
            if parts.count == 2, Self.isSensitiveKey(parts.first ?? "") {
                register(parts[1])
            }
        }
    }

    public mutating func register(_ value: String) {
        if !value.isEmpty {
            secrets.insert(value)
        }
    }

    public func redact(_ value: String) -> String {
        secrets.sorted { $0.count > $1.count }.reduce(value) { result, secret in
            result.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }

    public func environment(_ values: [String: String]) -> [String: String] {
        values.mapValues(redact)
    }

    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return ["password", "passwd", "secret", "token", "api_key", "apikey", "credential", "authorization"]
            .contains { normalized.contains($0) }
    }

    /// Removes URL credentials and query values; URL structure remains useful as diagnostic evidence.
    public static func redactedURL(_ raw: String) -> String {
        guard var url = URLComponents(string: raw) else { return "<redacted URL>" }
        if url.user != nil {
            url.user = "redacted"
        }
        if url.password != nil {
            url.password = "redacted"
        }
        url.queryItems = url.queryItems?.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "redacted") }
        if url.fragment != nil {
            url.fragment = "redacted"
        }
        return url.string ?? "<redacted URL>"
    }
}
