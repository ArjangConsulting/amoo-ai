import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    // MARK: - Session tools

    func executeStartSession(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured. Run `amoo mcp serve` to enable.")
        }
        guard let appID = arguments["app_id"] else {
            return .error("Missing required argument: app_id")
        }
        let platformRaw = arguments["platform"] ?? "ios"
        guard let platform = Platform(rawValue: platformRaw.lowercased()) else {
            return .error("Unknown platform '\(platformRaw)'. Expected 'ios' or 'android'.")
        }
        let deviceHint = arguments["device_hint"]
        let buildPath = arguments["build_path"]
        let launchArgs: [String] = arguments["launch_args"]
            .map { $0.split(separator: ",").map(String.init) } ?? []
        let environment = Self.parseEnvironment(arguments["environment"])

        do {
            let session = try await manager.startSession(
                appID: appID,
                platform: platform,
                deviceHint: deviceHint,
                buildPath: buildPath,
                arguments: launchArgs,
                environment: environment
            )
            let summary: [String: Value] = [
                "session_id": .string(session.id),
                "app_id": .string(session.appID),
                "device_id": .string(session.deviceID),
                "platform": .string(session.platform.rawValue)
            ]
            let text = "Started session \(session.id) for \(session.appID) on \(session.platform.rawValue)"
                + " device \(session.deviceID)."
            return .success(text, structuredContent: .object(summary))
        } catch {
            return .error("start_session failed: \(error)")
        }
    }

    func executeEndSession(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        guard let sessionID = arguments["session_id"] else {
            return .error("Missing required argument: session_id")
        }

        // Capture action count before close.
        let actionCount: Int
        if let session = await manager.session(sessionID) {
            actionCount = await session.actions.count
        } else {
            return .error("Session not found: \(sessionID)")
        }

        do {
            try await manager.endSession(sessionID)
        } catch {
            return .error("end_session failed: \(error)")
        }

        let summary: [String: Value] = [
            "session_id": .string(sessionID),
            "ended_at": .string(ISO8601DateFormatter().string(from: Date())),
            "action_count": .int(actionCount)
        ]
        return .success(
            "Ended session \(sessionID) (\(actionCount) action(s) recorded).",
            structuredContent: .object(summary)
        )
    }

    func executeListSessions() async -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        let sessions = await manager.allSessions()
        var rows: [Value] = []
        var lines: [String] = []
        for session in sessions {
            let count = await session.actions.count
            let isActive = await session.isActive
            rows.append(.object([
                "session_id": .string(session.id),
                "app_id": .string(session.appID),
                "device_id": .string(session.deviceID),
                "platform": .string(session.platform.rawValue),
                "started_at": .string(ISO8601DateFormatter().string(from: session.startedAt)),
                "action_count": .int(count),
                "is_active": .bool(isActive)
            ]))
            lines.append(
                "[\(session.id)] \(session.appID) on \(session.platform.rawValue) — \(count) action(s)"
                    + (isActive ? "" : " (closed)")
            )
        }
        let summary = lines.isEmpty ? "No active sessions." : lines.joined(separator: "\n")
        return .success(summary, structuredContent: .object(["sessions": .array(rows)]))
    }

    func executeGetSessionReport(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        guard let sessionID = arguments["session_id"] else {
            return .error("Missing required argument: session_id")
        }
        guard let session = await manager.session(sessionID) else {
            return .error("Session not found: \(sessionID)")
        }
        let report = await SessionReport.make(from: session)
        let summary = "Session \(report.sessionID) — \(report.actionCount) action(s), \(report.errorCount) error(s)."
        return try .success(summary, structuredContent: Value(report))
    }

    // MARK: - Device discovery / app inventory

    func executeListDevices(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured. Device discovery requires it.")
        }
        let platformFilter: Platform?
        if let raw = arguments["platform"] {
            guard let parsed = Platform(rawValue: raw.lowercased()) else {
                return .error("Unknown platform '\(raw)'. Expected 'ios' or 'android'.")
            }
            platformFilter = parsed
        } else {
            platformFilter = nil
        }

        let devices = try await manager.listAvailableDevices(platform: platformFilter)
        var rows: [Value] = []
        var lines: [String] = []
        for device in devices {
            rows.append(.object([
                "id": .string(device.id),
                "name": .string(device.name),
                "platform": .string(device.platform.rawValue),
                "os_version": .string(device.osVersion),
                "state": .string(device.state.rawValue)
            ]))
            lines.append("[\(device.platform.rawValue)] \(device.name) (\(device.id)) — \(device.state.rawValue)")
        }
        let text = lines.isEmpty ? "No devices found." : lines.joined(separator: "\n")
        return .success(text, structuredContent: .object(["devices": .array(rows)]))
    }

    func formatListApps(_ apps: [AppInfo]) -> ToolResult {
        var rows: [Value] = []
        var lines: [String] = []
        for app in apps {
            var fields: [String: Value] = ["app_id": .string(app.appID)]
            if let name = app.name {
                fields["name"] = .string(name)
            }
            if let version = app.version {
                fields["version"] = .string(version)
            }
            rows.append(.object(fields))
            let suffix = [app.name, app.version].compactMap(\.self).joined(separator: " ")
            lines.append(suffix.isEmpty ? app.appID : "\(app.appID) — \(suffix)")
        }
        let text = lines.isEmpty ? "No installed apps reported." : lines.joined(separator: "\n")
        return .success(text, structuredContent: .object(["apps": .array(rows)]))
    }

    // MARK: - Intent tools
}
