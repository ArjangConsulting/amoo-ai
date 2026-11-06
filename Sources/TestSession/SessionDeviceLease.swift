import Foundation

/// Advisory device ownership, including process locks that have no fixed expiry.
public struct SessionDeviceLease: Sendable, Codable {
    public let owner: String
    public let runtimeID: String?
    public let expiresAt: String?

    public init(owner: String, runtimeID: String? = nil, expiresAt: String? = nil) {
        self.owner = owner
        self.runtimeID = runtimeID
        self.expiresAt = expiresAt
    }
}
