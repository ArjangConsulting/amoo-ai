/// What the host can establish about launch configuration delivery, independent of app behavior.
public struct AppLaunchReceipt: Codable, Sendable, Equatable {
    public let appID: String
    public let freshProcess: Bool?
    public let environmentDelivery: String
    public let environmentKeys: [String]

    public init(appID: String, freshProcess: Bool?, environmentDelivery: String, environmentKeys: [String]) {
        self.appID = appID
        self.freshProcess = freshProcess
        self.environmentDelivery = environmentDelivery
        self.environmentKeys = environmentKeys.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case freshProcess = "fresh_process"
        case environmentDelivery = "environment_delivery"
        case environmentKeys = "environment_keys"
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
