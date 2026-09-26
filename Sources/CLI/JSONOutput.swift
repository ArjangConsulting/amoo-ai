import Foundation
import MCP

/// One JSON object per CLI call (`--json`): sorted keys, ISO-8601 dates, no pretty-printing, so a
/// caller's context holds a single compact line.
func renderJSON(_ value: some Encodable) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value), let text = String(bytes: data, encoding: .utf8) else {
        return #"{"ok":false,"error":"failed to encode JSON output"}"#
    }
    return text
}

private struct DeviceCommandJSON: Encodable {
    let tool: String
    let ok: Bool
    let content: String
    let structured: Value?
}

func deviceCommandResult(
    options: DeviceCommandOptions,
    content: String,
    isError: Bool,
    structured: Value?
) -> CLIResult {
    let output = options.json
        ? renderJSON(DeviceCommandJSON(tool: options.tool, ok: !isError, content: content, structured: structured))
        : content
    return CLIResult(output: output, exitCode: isError ? 1 : 0)
}
