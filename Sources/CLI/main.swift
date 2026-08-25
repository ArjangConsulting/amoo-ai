import CLIReadline
import Foundation

// C stdio fully buffers stdout by default whenever it isn't a TTY (piped, redirected to a
// file, or captured by a harness) — status lines like "Building...", "Installing...", and
// "Companion ready" only flush once the buffer fills or the process exits, so long-running
// commands like `companion start` look hung to anything not reading an interactive terminal.
// Line-buffer instead so each `print()` call flushes immediately, matching TTY behavior.
// Done via a C shim (see CLIReadline.h) so Swift never references the `stdout` global directly —
// Swift 6's strict concurrency checking flags that as non-Sendable global state on Linux.
cli_line_buffer_stdout()

let app = CLIApp()
let result = await app.run(args: Array(CommandLine.arguments.dropFirst()))
if !result.output.isEmpty {
    print(result.output)
}

exit(result.exitCode)
