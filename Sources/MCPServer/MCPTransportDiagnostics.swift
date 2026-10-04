import Foundation

/// Opt-in, payload-free lifecycle evidence for diagnosing client transport closures.
struct MCPTransportDiagnostics: Sendable {
    let enabled = ProcessInfo.processInfo.environment["AMOO_MCP_DIAGNOSTICS"] == "1"

    func emit(_ event: String) {
        guard enabled else { return }
        let line = "amoo.mcp pid=\(ProcessInfo.processInfo.processIdentifier)"
            + " timestamp=\(ISO8601DateFormatter().string(from: Date())) event=\(event)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }

    func inputFailure(_ error: any Error) {
        switch error {
        case MCPRequestRuntime.InputError.oversizedFrame: emit("input_oversized_frame")
        case MCPRequestRuntime.InputError.backpressure: emit("input_backpressure")
        default: emit("input_error")
        }
    }
}
