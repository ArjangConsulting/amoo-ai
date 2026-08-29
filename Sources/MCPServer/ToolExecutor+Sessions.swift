import AmooCore
import AuditEngine
import Foundation
import MCP
import StudioProtocol
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

        guard await manager.session(sessionID) != nil else {
            return .error("Session not found: \(sessionID)")
        }

        do {
            try await manager.endSession(sessionID)
        } catch {
            return .error("end_session failed: \(error)")
        }

        var summary: [String: Value] = [
            "session_id": .string(sessionID),
            "ended_at": .string(ISO8601DateFormatter().string(from: Date()))
        ]

        // Auto-compile the recorded history into replayable artifacts on close, so
        // every driven flow leaves a plan behind without a separate opt-in call.
        let report = await manager.report(for: sessionID)
        let actionCount = report?.actionCount ?? 0
        summary["action_count"] = .int(actionCount)

        // `end_session` advertises plan_path/flow_path in its output schema, so a failure to produce
        // them has to be visible — silently omitting the keys is indistinguishable from "no store
        // configured", and the caller cannot tell it needs to re-run compile_session_to_plan.
        var artifactNote = ""
        let directory = await manager.sessionDirectory(for: sessionID)
        if let report, let directory {
            do {
                let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
                let paths = try SessionArtifactWriter.write(result, to: directory)
                summary["plan_path"] = .string(paths.plan)
                summary["flow_path"] = .string(paths.flow)
                summary["warning_count"] = .int(result.warnings.count)
                artifactNote = " Plan written to \(paths.plan)"
                    + (result.warnings.isEmpty ? "" : " (\(result.warnings.count) warning(s))") + "."
            } catch {
                summary["artifact_error"] = .string("\(error)")
                artifactNote = " Could not write replay artifacts: \(error)."
                    + " Re-run compile_session_to_plan to retry."
            }
        } else if directory == nil {
            artifactNote = " No session store is configured, so no replay artifacts were written;"
                + " call compile_session_to_plan to keep this run."
        }

        return .success(
            "Ended session \(sessionID) (\(actionCount) action(s) recorded).\(artifactNote)",
            structuredContent: .object(summary)
        )
    }

    func executeListSessions() async -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        let reports = await manager.allReports()
        var rows: [Value] = []
        var lines: [String] = []
        for report in reports {
            rows.append(.object([
                "session_id": .string(report.sessionID),
                "app_id": .string(report.appID),
                "device_id": .string(report.deviceID),
                "platform": .string(report.platform),
                "started_at": .string(ISO8601DateFormatter().string(from: report.startedAt)),
                "action_count": .int(report.actionCount),
                "is_active": .bool(report.isActive)
            ]))
            lines.append(
                "[\(report.sessionID)] \(report.appID) on \(report.platform) — \(report.actionCount) action(s)"
                    + (report.isActive ? "" : " (closed)")
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
        guard let report = await manager.report(for: sessionID) else {
            return .error("Session not found: \(sessionID)")
        }
        let summary = "Session \(report.sessionID) — \(report.actionCount) action(s), \(report.errorCount) error(s)."
        return try .success(summary, structuredContent: Value(report))
    }

    func executeCompileSessionToPlan(arguments: [String: String]) async throws -> ToolResult {
        guard let manager = sessionManager else {
            return .error("Session management not configured.")
        }
        guard let sessionID = arguments["session_id"] else {
            return .error("Missing required argument: session_id")
        }
        guard let report = await manager.report(for: sessionID) else {
            return .error("Session not found: \(sessionID)")
        }
        let result: CompileSessionToPlanResult
        do {
            result = try SessionPlanCompiler.compile(
                report: report,
                testName: arguments["test_name"],
                testDescription: arguments["test_description"]
            )
        } catch let error as SessionPlanCompilerError {
            return .error(error.description)
        }

        // Overwrite the auto-written artifacts with this named version. Say so either way: the
        // caller's next step is `amoo generate test --plan <path>`, and a silent no-write leaves it
        // pointing at a stale file.
        var artifactNote = ""
        if let directory = await manager.sessionDirectory(for: sessionID) {
            do {
                let paths = try SessionArtifactWriter.write(result, to: directory)
                artifactNote = " Written to \(paths.plan)."
            } catch {
                artifactNote = " Compiled in memory only — writing to \(directory.path) failed: \(error)."
            }
        } else {
            artifactNote = " No session store is configured, so nothing was written to disk."
        }

        let summary = "Compiled session \(sessionID) into \(result.testFlow.steps.count) flow step(s),"
            + " \(result.studioTest.compiledPlan?.toolOperations?.count ?? 0) plan operation(s),"
            + " \(result.warnings.count) warning(s).\(artifactNote)"
        return try .success(summary, structuredContent: Value(result))
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
