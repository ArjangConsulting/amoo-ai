import AmooCore
import AmooTelemetry
import Foundation
import SwiftyTerminal
import TestSession
import Tracing

// C stdio fully buffers stdout by default whenever it isn't a TTY (piped, redirected to a
// file, or captured by a harness) — status lines like "Building...", "Installing...", and
// "Companion ready" only flush once the buffer fills or the process exits, so long-running
// commands like `companion start` look hung to anything not reading an interactive terminal.
// Line-buffer instead so each `print()` call flushes immediately, matching TTY behavior.
// SwiftyTerminal does this in C so Swift never references the `stdout` global directly —
// Swift 6's strict concurrency checking flags that as non-Sendable global state on Linux.
StandardTerminal.lineBufferStandardOutput()

let arguments = Array(CommandLine.arguments.dropFirst())
let telemetry = AmooTelemetry.bootstrap(.fromEnvironment(
    ProcessInfo.processInfo.environment,
    serviceVersion: AmooBuildInfo.current.version,
    localDirectory: FileSessionStore().root.appending(path: "telemetry")
))
let command = TelemetryNaming.command(arguments) ?? "help"
let result = await TelemetryCallContext.$current.withValue(TelemetryCallContext(surface: "cli")) {
    // A long-lived MCP server gets one span per request instead of one span for its lifetime.
    if command.hasPrefix("mcp") {
        return await CLIApp().run(args: arguments)
    }
    return await withSpan("amoo \(command)") { span in
        let result = await CLIApp().run(args: arguments)
        span.attributes[TelemetryAttribute.processExitCode] = Int(result.exitCode)
        if result.exitCode != 0 {
            span.setStatus(SpanStatus(code: .error))
        }
        return result
    }
}

if !result.output.isEmpty {
    print(result.output)
}

await telemetry.shutdown()
exit(result.exitCode)
