import ProcessRunner
import WebInspector

/// Bridges `WebInspector`'s minimal shell protocol to the CLI's `ProcessRunner`, so the WebView
/// tools can drive `adb` without `WebInspector` depending on `ProcessRunner`.
struct WebInspectorShellAdapter: WebInspectorShell {
    let processRunner: any ProcessRunner

    func run(_ arguments: [String]) async throws -> WebInspectorShellResult {
        let result = try await processRunner.run(arguments)
        return WebInspectorShellResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
}

/// The live resolver used by `amoo device` and `amoo mcp serve`.
func makeWebInspecting(processRunner: any ProcessRunner) -> any WebInspecting {
    PlatformWebInspecting(shell: WebInspectorShellAdapter(processRunner: processRunner))
}
