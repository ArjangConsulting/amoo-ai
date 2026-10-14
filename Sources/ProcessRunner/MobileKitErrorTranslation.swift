import MobileCore

/// Runs `body`, rethrowing a failed MobileDevices command as ``ProcessRunnerError/nonZeroExit``.
///
/// Amoo reports tool failures as ``ProcessRunnerError``; the `MobileDevices` managers throw
/// ``MobileKitError``. Translating at this boundary keeps the error contract the runners' callers
/// and error messages already rely on. Other errors (timeouts, missing tools) pass through.
func translatingMobileKitErrors<Result>(_ body: () async throws -> Result) async throws -> Result {
    do {
        return try await body()
    } catch let MobileKitError.commandFailed(command, exitCode, output) {
        throw ProcessRunnerError.nonZeroExit(
            command: command.joined(separator: " "), exitCode: exitCode, stderr: output
        )
    }
}
