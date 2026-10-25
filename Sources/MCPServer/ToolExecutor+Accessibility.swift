// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP

extension DriverToolExecutor {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func executeAccessibilityInspection(
        driver: any PlatformDriver, arguments: [String: String], toolName: String
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"], !appID.isEmpty else {
            throw ToolExecutionError(code: "invalid_argument", message: "Requires app_id")
        }
        if let id = arguments["session_id"], let session = await sessionManager?.session(id), session.appID != appID {
            throw ToolExecutionError(
                code: "wrong_app",
                message: "Inspection target must match the session's app identity"
            )
        }
        let current = try await driver.currentApp()
        guard current.bundleID == appID else {
            throw ToolExecutionError(code: "wrong_app", message: "Inspection target is not the frontmost app")
        }
        let operation = ["test_talkback", "assert_talkback_speech"]
            .contains(toolName) ? "talkBack" : toolName == "test_voiceover" ? "voiceOver" : "nativeAudit"
        let platform = try? await driver.deviceInfo().platform
        let defaults = platform == .android ? AccessibilityInspectionOptions.androidAuditCategories
            : AccessibilityInspectionOptions.iosAuditCategories
        let categories = arguments["categories"]
            .map {
                $0.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            ?? defaults.sorted()
        let speech: [AccessibilitySpeechExpectation]
        if toolName == "assert_talkback_speech" {
            guard let raw = arguments["speech"],
                  let decoded = try? JSONDecoder().decode([AccessibilitySpeechExpectation].self, from: Data(raw.utf8))
            else {
                throw ToolExecutionError(code: "invalid_argument", message: "speech requires a JSON expectation array")
            }
            speech = decoded
        } else {
            speech = []
        }
        let steps: Int
        if let value = arguments["steps"] {
            guard let count = Int(value) else {
                throw ToolExecutionError(code: "invalid_argument", message: "steps must be an integer")
            }
            steps = count
        } else {
            steps = speech.isEmpty ? 5 : speech.count
        }
        if toolName == "assert_talkback_speech" {
            try AccessibilityInspectionOptions.validateSpeech(speech, steps: steps)
        }
        let direction = arguments["direction"] ?? "forward"
        try AccessibilityInspectionOptions.validate(
            operation: operation, categories: categories, steps: steps, direction: direction
        )
        let phases = try inspectionPhases(arguments: arguments, operation: operation)
        let baseline = operation == "nativeAudit" ? await Self.withinBudget(milliseconds: 1500) {
            try? await driver.observeScreen(appID: appID)
        } : nil
        var report = if operation == "talkBack" {
            try await driver.inspectTalkBack(
                appID: appID, steps: steps, direction: direction, activate: boolArgument(arguments["activate"]) == true,
                speechExpectations: speech
            )
        } else if phases.isEmpty {
            try await driver.inspectAccessibility(
                appID: appID, operation: operation, categories: categories, steps: steps, direction: direction
            )
        } else {
            try await driver.inspectVoiceOver(appID: appID, phases: phases)
        }
        if report.requestedChecks.isEmpty {
            report.requestedChecks = operation == "nativeAudit" ? categories
                : (phases.isEmpty ? [VoiceOverPhase(steps: steps, direction: direction)] : phases).indices.map {
                    "traversal.phase.\($0)"
                }
            report.notEvaluatedReasons = Dictionary(report.requestedChecks.map {
                ($0, report.error ?? "Companion did not supply evaluated coverage")
            }, uniquingKeysWith: { first, _ in first })
        }
        report = try await inspectionProvenance(report, driver: driver, arguments: arguments, appID: appID)
        let highlight = await inspectionHighlight(report: &report, baseline: baseline, driver: driver, appID: appID)
        if let path = arguments["output"] {
            if let highlight {
                let output = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try highlight.data.write(to: output, options: .atomic)
                report.provenance["annotated_screenshot_path"] = output.path
            } else {
                report.provenance["annotation_output_status"] = "unavailable: no correlated highlight was produced"
            }
        }
        return try ToolResult(
            content: "\(report.provider): execution=\(report.executionStatus), verdict=\(report.verdict),"
                + " cleanup=\(report.cleanupStatus). \(report.issues.count) issue(s),"
                + " \(report.utterances.count) observed utterance(s). \(report.error ?? "")",
            isError: report.executionStatus != "succeeded" || ["failed", "unknown"].contains(report.cleanupStatus)
                || (toolName == "assert_talkback_speech" && report.verdict != "pass"),
            structuredContent: Value(report),
            image: highlight
        )
    }

    private func inspectionPhases(arguments: [String: String], operation: String) throws -> [VoiceOverPhase] {
        if let raw = arguments["phases"] {
            guard operation == "voiceOver", arguments["steps"] == nil, arguments["direction"] == nil,
                  let decoded = try? JSONDecoder().decode([VoiceOverPhase].self, from: Data(raw.utf8)) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "phases requires a VoiceOver JSON array;"
                        + " omit steps and direction when providing phases"
                )
            }
            try VoiceOverPhase.validate(decoded)
            return decoded
        }
        return []
    }
}

// swiftlint:enable multiline_arguments
