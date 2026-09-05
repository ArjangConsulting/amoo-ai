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
    public var codegenIntent: SessionCodegenIntent?

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
        testName: String? = nil,
        codegenIntent: SessionCodegenIntent? = nil
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
        self.codegenIntent = codegenIntent
    }

    public static func make(from session: TestSession) async -> Self {
        await session.reportSnapshot()
    }

    /// Lightweight listing index; action counts are preserved without copying action payloads.
    public var summary: Self {
        Self(
            sessionID: sessionID,
            appID: appID,
            deviceID: deviceID,
            platform: platform,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: durationSeconds,
            actionCount: actionCount,
            errorCount: errorCount,
            isActive: isActive,
            actions: [],
            testName: testName
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, appID, deviceID, platform, startedAt, endedAt, durationSeconds
        case actionCount, errorCount, isActive, actions, launchArguments, launchEnvironment, testName, codegenIntent
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
            testName: container.decodeIfPresent(String.self, forKey: .testName),
            codegenIntent: container.decodeIfPresent(SessionCodegenIntent.self, forKey: .codegenIntent)
        )
    }
}

extension TestSession {
    /// Capture secrets, actions and lifecycle state in one actor turn. Separate awaits could
    /// combine a new action with an older redaction set during an idle flush.
    func reportSnapshot() -> SessionReport {
        let sanitizedActions = actions.map { $0.redacted(using: redactor) }
        let end = endedAt ?? Date()
        return SessionReport(
            sessionID: id,
            appID: appID,
            deviceID: deviceID,
            platform: platform.rawValue,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: end.timeIntervalSince(startedAt),
            actionCount: sanitizedActions.count,
            errorCount: sanitizedActions.reduce(0) { $0 + ($1.isError ? 1 : 0) },
            isActive: isActive,
            actions: sanitizedActions,
            launchArguments: launchArguments.map(redactor.redact),
            launchEnvironment: redactor.environment(launchEnvironment),
            testName: testName,
            codegenIntent: codegenIntent
        )
    }
}
