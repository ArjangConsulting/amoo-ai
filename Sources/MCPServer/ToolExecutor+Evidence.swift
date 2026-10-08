import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    static let diagnosticTools = DiagnosticEvidence.toolNames

    func diagnosticEvidence(
        toolName: String,
        arguments: [String: String],
        result: ToolResult
    ) -> DiagnosticEvidence? {
        guard DiagnosticEvidence.structuredToolNames.contains(toolName) else { return nil }
        let structured = result.structuredContent ?? .object([
            "executionStatus": .string(result.isError ? "failed" : "unknown"),
            "verdict": .string("notAssessed"), "error": .string(result.content)
        ])
        let retainSpeech = boolArgument(arguments["record_speech"]) == true
        let hasSpeech = ["test_voiceover", "assert_accessibility_journey"].contains(toolName)
        let filtered = hasSpeech && !retainSpeech ? Self.omittingSpeech(structured) : structured
        guard let data = try? JSONEncoder().encode(filtered),
              let payload = try? JSONDecoder().decode(DiagnosticValue.self, from: data) else { return nil }
        return DiagnosticEvidence(payload: payload, speechRetained: hasSpeech && retainSpeech)
    }

    private static func omittingSpeech(_ value: Value) -> Value {
        switch value {
        case let .object(fields):
            .object(fields.mapValues { omittingSpeech($0) }.merging(
                (fields["utterances"].map { ["utterances": omittingUtterances($0)] } ?? [:]).merging(
                    fields["source"] == .string("voiceOverSpeech") ? ["actual": .string("<speech not retained>")] : [:],
                    uniquingKeysWith: { _, replacement in replacement }
                ),
                uniquingKeysWith: { _, replacement in replacement }
            ))
        case let .array(items): .array(items.map(omittingSpeech))
        default: value
        }
    }

    private static func omittingUtterances(_ value: Value) -> Value {
        guard case let .array(items) = value else { return .null }
        return .array(items.map { _ in .string("<speech not retained; use record_speech=true to opt in>") })
    }
}
