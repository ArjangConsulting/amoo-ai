import AmooCore
import MCP

extension DriverToolExecutor {
    func outcomeFields(_ original: ToolResult, tool: String) -> ToolResult {
        var fields = original.structuredContent?.objectValue ?? [:]
        if tool.hasPrefix("assert_") {
            fields["postcondition_verified"] = .bool(!original.isError && fields["passed"] == .bool(true))
            fields["outcome_status"] = .string(
                !original.isError && fields["passed"] == .bool(true) ? "target_state_confirmed"
                    : fields["failure_kind"] == .string("assertion_mismatch") ? "target_state_mismatch" : "inconclusive"
            )
        } else if !ToolCatalogMetadata.isReadOnly(tool), !Self.controlPlaneTools.contains(tool), tool != "run_steps" {
            if fields["dispatch_status"] == nil {
                let rejected = ["invalid_argument", "element_not_found", "ambiguous_selector", "stale_screen"]
                    .contains(fields["code"]?.stringValue ?? "")
                fields["dispatch_status"] = .string(original
                    .isError ? rejected ? "not_dispatched" : "unknown" : "completed")
            }
            let fieldConfirmed = ["set_text", "fill_field"].contains(tool)
                && fields["verification_mode"] == .string("exact")
            let confirmed = !original.isError && (fieldConfirmed || fields["postcondition_verified"] == .bool(true))
            fields["outcome_status"] = .string(confirmed ? "target_state_confirmed"
                : !original
                .isError && fields["dispatch_status"] == .string("completed") ? "dispatched" : "inconclusive")
            fields["postcondition_verified"] = .bool(confirmed)
        } else {
            return original
        }
        var result = original
        result.structuredContent = .object(fields)
        return result
    }

    func executionFailureDiagnostics(
        _ result: ToolResult,
        tool: String,
        started: ContinuousClock.Instant,
        dispatchStarted: Bool
    ) -> ToolResult {
        let duration = started.duration(to: .now).components
        let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        var fields = result.structuredContent?.objectValue ?? [:]
        let readOnly = ToolCatalogMetadata.isReadOnly(tool)
        fields["elapsed_ms"] = .int(milliseconds)
        fields["dispatch_status"] =
            .string(readOnly ? "not_applicable" : dispatchStarted ? "unknown" : "not_dispatched")
        fields["last_observed_state"] = .string("unavailable")
        fields["companion_health"] = .string("unconfirmed")
        fields["device_health"] = .string("unconfirmed")
        fields["last_successful_stage"] = .string(dispatchStarted ? "host_dispatch_started" : "request_received")
        let note = readOnly || !dispatchStarted ? "" : "\nAction dispatch/application is unknown. Inspect the current"
            + " state before retrying; a timeout does not prove the gesture was cancelled."
        return ToolResult(content: result.content + note, isError: true, structuredContent: .object(fields))
    }
}
