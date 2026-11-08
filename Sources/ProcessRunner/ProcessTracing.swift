import AmooTelemetry
import Foundation
import Tracing

/// Wraps subprocesses (`adb`, `xcrun simctl`, `devicectl`, …) in OpenTelemetry spans. Only the
/// executable name and a short, low-cardinality subcommand are recorded — never arguments, which
/// can carry typed text, paths or device identifiers.
enum ProcessTracing {
    static func trace(
        executable: String,
        arguments: [String],
        _ operation: () async throws -> ProcessResult
    ) async throws -> ProcessResult {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        return try await withSpan("exec \(name)", ofKind: .client) { span in
            span.attributes[TelemetryAttribute.processExecutableName] = name
            if let subcommand = TelemetryNaming.command(arguments) {
                span.attributes[TelemetryAttribute.processSubcommand] = subcommand
            }
            let result = try await operation()
            span.attributes[TelemetryAttribute.processExitCode] = Int(result.exitCode)
            if result.exitCode != 0 {
                span.attributes[TelemetryAttribute.errorType] = "exit_\(result.exitCode)"
                span.setStatus(SpanStatus(code: .error))
            }
            return result
        }
    }
}
