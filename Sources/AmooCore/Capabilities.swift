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

/// Provider-level promises; conditional state still requires the property's presence on an element.
public struct InspectionCapabilities: Sendable, Equatable {
    public let provider: String
    public let assertions: [String: String]

    public init(platform: Platform? = nil, provider: String = "unknown") {
        self.provider = provider
        let state = platform == nil ? "unknown" : platform == .android ? "conditional" : "unsupported"
        assertions = [
            "assert_visible": platform == nil ? "unknown" : "supported",
            "assert_absent": platform == nil ? "unknown" : "supported",
            "assert_enabled": platform == nil ? "unknown" : "supported",
            "assert_value": platform == nil ? "unknown" : "conditional",
            "assert_selected": platform == nil ? "unknown" : "conditional",
            "assert_checked": state, "assert_state_description": state
        ]
    }
}
