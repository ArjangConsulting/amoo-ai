import MobileCore

/// Runs `body`, rethrowing a failed MobileDevices command as ``ProcessRunnerError/nonZeroExit`` and a
/// timed-out one as ``ProcessRunnerError/deviceUnresponsive``.
///
/// Amoo reports tool failures as ``ProcessRunnerError``; the `MobileDevices` managers throw
/// ``MobileKitError``. Translating at this boundary keeps the error contract the runners' callers
/// and error messages already rely on. A timed-out `am force-stop` used to read as a launch failure;
/// it means the device stopped answering. Other errors (missing tools) pass through.
func translatingMobileKitErrors<Result>(_ body: () async throws -> Result) async throws -> Result {
    do {
        return try await body()
    } catch let MobileKitError.commandFailed(command, exitCode, output) {
        throw ProcessRunnerError.failed(command: command.joined(separator: " "), exitCode: exitCode, output: output)
    } catch let MobileKitError.timedOut(operation, seconds) {
        throw ProcessRunnerError.deviceUnresponsive(operation: operation, seconds: Int(seconds))
    }
}
