public enum CapabilityTier: Sendable, Equatable {
    case required
    case optional
}

public struct CapabilityDescriptor: Sendable, Equatable {
    public var key: String
    public var tier: CapabilityTier
    public var supported: Bool
    public var reasonIfUnsupported: String?

    public init(key: String, tier: CapabilityTier, supported: Bool, reasonIfUnsupported: String? = nil) {
        self.key = key
        self.tier = tier
        self.supported = supported
        self.reasonIfUnsupported = reasonIfUnsupported
    }
}
