import AmooCore
import Foundation

/// Serializable snapshot of a session's full action history. Returned by
/// the MCP `get_session_report` tool.
public struct SessionReport: Sendable, Codable, Equatable {
    public let sessionID: String
    public let appID: String
    public let deviceID: String
    /// `Platform.rawValue` — stored as String to keep the report free of
    /// retroactive Codable conformances.
    public let platform: String
    public let startedAt: Date
    public let endedAt: Date?
    public let durationSeconds: Double
    public let actionCount: Int
    public let errorCount: Int
    public let isActive: Bool
    public let actions: [SessionAction]
    public let launchArguments: [String]
    public let launchEnvironment: [String: String]
    public let testName: String?

    public init(
        sessionID: String,
        appID: String,
        deviceID: String,
        platform: String,
        startedAt: Date,
        endedAt: Date?,
        durationSeconds: Double,
        actionCount: Int,
        errorCount: Int,
        isActive: Bool,
        actions: [SessionAction],
        launchArguments: [String] = [],
        launchEnvironment: [String: String] = [:],
        testName: String? = nil
    ) {
        self.sessionID = sessionID
        self.appID = appID
        self.deviceID = deviceID
        self.platform = platform
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.actionCount = actionCount
        self.errorCount = errorCount
        self.isActive = isActive
        self.actions = actions
        self.launchArguments = launchArguments
        self.launchEnvironment = launchEnvironment
        self.testName = testName
    }

    public static func make(from session: TestSession) async -> Self {
        let actions = await session.actions
        let endedAt = await session.endedAt
        let isActive = await session.isActive
        let end = endedAt ?? Date()
        return Self(
            sessionID: session.id,
            appID: session.appID,
            deviceID: session.deviceID,
            platform: session.platform.rawValue,
            startedAt: session.startedAt,
            endedAt: endedAt,
            durationSeconds: end.timeIntervalSince(session.startedAt),
            actionCount: actions.count,
            errorCount: actions.reduce(0) { $0 + ($1.isError ? 1 : 0) },
            isActive: isActive,
            actions: actions,
            launchArguments: session.launchArguments,
            launchEnvironment: session.launchEnvironment,
            testName: session.testName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, appID, deviceID, platform, startedAt, endedAt, durationSeconds
        case actionCount, errorCount, isActive, actions, launchArguments, launchEnvironment, testName
    }

    /// ISO-8601 *with* fractional seconds. The single source of truth for how a `report.json` is
    /// written and read — used by `FileSessionStore` and by every offline reader
    /// (`amoo generate plan`, tests), so a report round-trips identically whichever path touches it.
    ///
    /// `JSONEncoder.dateEncodingStrategy = .iso8601` uses `ISO8601DateFormatter`'s defaults, which
    /// omit fractional seconds — that truncated every action timestamp to a whole second on the way
    /// to disk and silently destroyed the only data the retry-collapse heuristic runs on (a live
    /// compile saw gaps of 2.461s / 2.449s; the same session recompiled after a restart saw 2.0s /
    /// 2.0s). `Date.ISO8601FormatStyle` is a `Sendable` value type, so it can live in a `static let`
    /// under strict concurrency. Reads accept the no-fraction form too, for reports written before
    /// this fix.
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalStyle.format(date))
        }
        return encoder
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? fractionalStyle.parse(raw) {
                return date
            }
            if let date = try? plainStyle.parse(raw) {
                return date
            }
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an ISO-8601 date, got '\(raw)'."
            ))
        }
        return decoder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(String.self, forKey: .sessionID),
            appID: container.decode(String.self, forKey: .appID),
            deviceID: container.decode(String.self, forKey: .deviceID),
            platform: container.decode(String.self, forKey: .platform),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
            durationSeconds: container.decode(Double.self, forKey: .durationSeconds),
            actionCount: container.decode(Int.self, forKey: .actionCount),
            errorCount: container.decode(Int.self, forKey: .errorCount),
            isActive: container.decode(Bool.self, forKey: .isActive),
            actions: container.decode([SessionAction].self, forKey: .actions),
            launchArguments: container.decodeIfPresent([String].self, forKey: .launchArguments) ?? [],
            launchEnvironment: container.decodeIfPresent([String: String].self, forKey: .launchEnvironment) ?? [:],
            testName: container.decodeIfPresent(String.self, forKey: .testName)
        )
    }
}
