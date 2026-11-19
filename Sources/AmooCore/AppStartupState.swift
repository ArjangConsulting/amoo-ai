/// What the host can establish about launch configuration delivery, independent of app behavior.
public struct AppLaunchReceipt: Codable, Sendable, Equatable {
    public let appID: String
    public let freshProcess: Bool?
    public let environmentDelivery: String
    public let environmentKeys: [String]
    /// How launch arguments reached the app (`process_arguments`, `intent_extras`), `not_requested`
    /// when none were passed, or `unknown`. Like the environment, delivery is not app behavior.
    public let argumentsDelivery: String
    /// How many launch arguments were passed. Their values are never reported.
    public let argumentCount: Int

    public init(
        appID: String,
        freshProcess: Bool?,
        environmentDelivery: String,
        environmentKeys: [String],
        argumentsDelivery: String = "unknown",
        argumentCount: Int = 0
    ) {
        self.appID = appID
        self.freshProcess = freshProcess
        self.environmentDelivery = environmentDelivery
        self.environmentKeys = environmentKeys.sorted()
        self.argumentsDelivery = argumentsDelivery
        self.argumentCount = argumentCount
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case freshProcess = "fresh_process"
        case environmentDelivery = "environment_delivery"
        case environmentKeys = "environment_keys"
        case argumentsDelivery = "arguments_delivery"
        case argumentCount = "argument_count"
    }

    /// Reports written before argument delivery was recorded decode it as `unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            appID: container.decode(String.self, forKey: .appID),
            freshProcess: container.decodeIfPresent(Bool.self, forKey: .freshProcess),
            environmentDelivery: container.decode(String.self, forKey: .environmentDelivery),
            environmentKeys: container.decode([String].self, forKey: .environmentKeys),
            argumentsDelivery: container.decodeIfPresent(String.self, forKey: .argumentsDelivery) ?? "unknown",
            argumentCount: container.decodeIfPresent(Int.self, forKey: .argumentCount) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appID, forKey: .appID)
        if let freshProcess {
            try container.encode(freshProcess, forKey: .freshProcess)
        } else {
            try container.encodeNil(forKey: .freshProcess)
        }
        try container.encode(environmentDelivery, forKey: .environmentDelivery)
        try container.encode(environmentKeys, forKey: .environmentKeys)
        try container.encode(argumentsDelivery, forKey: .argumentsDelivery)
        try container.encode(argumentCount, forKey: .argumentCount)
    }
}

/// Installation, launch and observation readiness are separate facts; none proves a requirement.
public struct AppStartupState: Codable, Sendable, Equatable {
    public let installation: String
    public let launch: AppLaunchReceipt
    public let semanticReadiness: String
    public let renderReadiness: String

    public init(installation: String, launch: AppLaunchReceipt, semanticReadiness: String) {
        self.installation = installation
        self.launch = launch
        self.semanticReadiness = semanticReadiness
        renderReadiness = "unverified"
    }

    enum CodingKeys: String, CodingKey {
        case installation, launch
        case semanticReadiness = "semantic_readiness"
        case renderReadiness = "render_readiness"
    }
}
