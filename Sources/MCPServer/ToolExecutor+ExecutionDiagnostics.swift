import AmooCore
import MCP

extension DriverToolExecutor {
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
