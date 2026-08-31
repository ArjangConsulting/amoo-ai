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
        let testName = arguments["test_name"]

        do {
            let session = try await manager.startSession(
                appID: appID,
                platform: platform,
                deviceHint: deviceHint,
                buildPath: buildPath,
                arguments: launchArgs,
                environment: environment,
                testName: testName
            )
            // Persist the codegen intent (descriptive name/description + app-owned test-context
            // reference) so `end_session`'s auto-compile reproduces the plan an explicit
            // `compile_session_to_plan` would — without recording a control-plane call as a step.
            await manager.rememberCodegenIntent(
                SessionCodegenIntent(
                    testName: testName,
                    testDescription: arguments["test_description"],
                    contextPath: arguments["context_path"],
                    contextJSON: arguments["context_json"]
                ),
                for: session.id
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
        let intent = await manager.codegenIntent(for: sessionID)
        if let report, let directory {
            do {
                var result = try SessionPlanCompiler.compile(
                    report: report,
                    testName: intent?.testName ?? report.testName,
                    testDescription: intent?.testDescription
                )
                result = try Self.applyingTestContext(intent, to: result)
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

    /// Puts the repeated-tap evidence in the text summary, not only the structured payload: the
    /// runs the window *declined* to collapse are what tell a caller it is set too low, and nobody
    /// tunes a threshold they cannot see.
    private func retryRunNote(for result: CompileSessionToPlanResult) -> String {
        guard result.retryRunObservations.isEmpty == false else { return "" }
        let collapsed = result.retryRunObservations.filter(\.collapsed)
        let kept = result.retryRunObservations.filter { $0.collapsed == false }

        var note = " Repeated-tap runs at the"
            + " \(String(format: "%.2fs", result.retryTapIntervalSeconds)) window:"
            + " \(collapsed.count) collapsed, \(kept.count) kept."
        for run in kept {
            let gaps = run.gaps.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
            note += " [kept] \(run.tapCount)x \(run.selector) (gaps \(gaps))."
        }
        if kept.isEmpty == false {
            note += " Raise retry_tap_interval_ms if those were retry loops."
        }
        return note
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
        // An explicit interval beats the env default. Reject junk rather than silently falling back:
        // a caller who passed the argument is tuning deliberately and needs to know it did nothing.
        var requestedInterval: TimeInterval?
        if let raw = arguments["retry_tap_interval_ms"] {
            guard let milliseconds = Double(raw), milliseconds > 0 else {
                return .error("retry_tap_interval_ms must be a positive number of milliseconds, got '\(raw)'.")
            }
            requestedInterval = milliseconds / 1000
        }

        // Refine (or seed) the session's codegen intent so a later `end_session` recompile keeps the
        // same descriptive name and app-owned test context this explicit call used.
        await manager.rememberCodegenIntent(
            SessionCodegenIntent(
                testName: arguments["test_name"],
                testDescription: arguments["test_description"],
                contextPath: arguments["context_path"],
                contextJSON: arguments["context_json"]
            ),
            for: sessionID
        )
        let intent = await manager.codegenIntent(for: sessionID)

        var result: CompileSessionToPlanResult
        do {
            result = try SessionPlanCompiler.compile(
                report: report,
                testName: arguments["test_name"] ?? intent?.testName ?? report.testName,
                testDescription: arguments["test_description"] ?? intent?.testDescription,
                retryTapInterval: requestedInterval
            )
            result = try Self.applyingTestContext(intent, to: result)
        } catch let error as SessionPlanCompilerError {
            return .error(error.description)
        } catch {
            return .error("compile_session_to_plan failed to load test context: \(error)")
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

        let retryNote = retryRunNote(for: result)

        let summary = "Compiled session \(sessionID) into \(result.testFlow.steps.count) flow step(s),"
            + " \(result.studioTest.compiledPlan?.toolOperations?.count ?? 0) plan operation(s),"
            + " \(result.warnings.count) warning(s).\(artifactNote)\(retryNote)"
        return try .success(summary, structuredContent: Value(result))
    }

    /// Loads the app-owned `StudioTestContext` named by a session's codegen intent (a file path or
    /// inline JSON) and folds it into the compiled plan, so the generated test uses the host's base
    /// class, app factory, imports, helpers, and selector expressions with no hand-editing.
    /// A no-op when the intent carries no context reference.
    static func applyingTestContext(
        _ intent: SessionCodegenIntent?,
        to result: CompileSessionToPlanResult
    ) throws -> CompileSessionToPlanResult {
        guard let intent else { return result }
        let data: Data
        if let json = intent.contextJSON, !json.isEmpty {
            data = Data(json.utf8)
        } else if let path = intent.contextPath, !path.isEmpty {
            data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            return result
        }
        let context = try JSONDecoder().decode(StudioTestContext.self, from: data)
        return CompileSessionToPlanResult(
            testFlow: result.testFlow,
            studioTest: result.studioTest.replacingTestContext(context),
            warnings: result.warnings,
            retryRunObservations: result.retryRunObservations,
            retryTapIntervalSeconds: result.retryTapIntervalSeconds
        )
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
