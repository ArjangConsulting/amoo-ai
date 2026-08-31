import Foundation

/// One-line JSON performance events. Values are intentionally compact and hierarchy contents are
/// never included, making the stream safe to collect from long MCP runs.
public enum PerformanceTelemetry {
    public static func record(
        _ category: String,
        operation: String,
        duration: Swift.Duration,
        metadata: [String: String] = [:]
    ) {
        guard ProcessInfo.processInfo.environment["AMOO_PERFORMANCE_TELEMETRY"] == "1" else { return }
        let components = duration.components
        let milliseconds = Double(components.seconds) * 1000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        var event: [String: Any] = metadata
        event["event"] = "amoo.performance"
        event["category"] = category
        event["operation"] = operation
        event["duration_ms"] = (milliseconds * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
