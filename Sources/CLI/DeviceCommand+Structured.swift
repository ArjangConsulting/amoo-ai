import Foundation
import MCP

func parseStructuredDeviceArguments(_ source: String) throws -> [String: String] {
    let data: Data
    if source.hasPrefix("@") {
        let url = URL(fileURLWithPath: String(source.dropFirst()))
        guard try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else {
            throw EnvCommandParseError.usage("Argument file exceeds 64 KiB")
        }
        data = try Data(contentsOf: url)
    } else {
        data = Data(source.utf8)
    }
    guard data.count <= 65536 else { throw EnvCommandParseError.usage("Arguments exceed 64 KiB") }
    let values = try JSONDecoder().decode([String: Value].self, from: data)
    return try values.mapValues { value in
        if let string = value.stringValue {
            return string
        }
        if value == .null {
            throw EnvCommandParseError.usage("Null arguments are unsupported; omit the key")
        }
        let encoded = try JSONEncoder().encode(value)
        guard let text = String(bytes: encoded, encoding: .utf8) else {
            throw EnvCommandParseError.usage("Arguments must be UTF-8")
        }
        return text
    }
}
