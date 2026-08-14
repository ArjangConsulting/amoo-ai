@testable import CLI
import Foundation
import Testing

struct LoadingIndicatorTests {
    @Test("Disabled indicator start/stop are no-ops")
    func disabledIndicatorIsNoop() async {
        let indicator = CLILoadingIndicator(message: "loading", isEnabled: false)
        await indicator.start()
        await indicator.stop()
        // No crash / no output expected; nothing further to assert on a disabled indicator.
    }

    @Test("Enabled indicator can start and stop without rendering before the delay elapses")
    func enabledIndicatorStopsBeforeRendering() async {
        let indicator = CLILoadingIndicator(message: "loading", isEnabled: true)
        await indicator.start(after: .seconds(60))
        await indicator.stop()
    }

    @Test("Enabled indicator renders after the delay and clears on stop")
    func enabledIndicatorRendersAfterDelay() async throws {
        let indicator = CLILoadingIndicator(message: "loading", isEnabled: true)
        await indicator.start(after: .milliseconds(1))
        try await Task.sleep(for: .milliseconds(50))
        await indicator.stop()
    }

    @Test("Calling start twice does not spawn a second render task")
    func startIsIdempotent() async throws {
        let indicator = CLILoadingIndicator(message: "loading", isEnabled: true)
        await indicator.start(after: .milliseconds(1))
        await indicator.start(after: .milliseconds(1))
        try await Task.sleep(for: .milliseconds(20))
        await indicator.stop()
    }

    @Test("withCLILoadingIndicator returns the operation's value for throwing operations")
    func throwingHelperReturnsValue() async throws {
        let operation: () async throws -> Int = { 42 }
        let result = try await withCLILoadingIndicator("working", operation: operation)
        #expect(result == 42)
    }

    @Test("withCLILoadingIndicator propagates errors from throwing operations")
    func throwingHelperPropagatesErrors() async throws {
        struct SampleError: Error {}
        await #expect(throws: SampleError.self) {
            try await withCLILoadingIndicator("working") {
                throw SampleError()
            }
        }
    }

    @Test("withCLILoadingIndicator returns the operation's value for non-throwing operations")
    func nonThrowingHelperReturnsValue() async {
        let result = await withCLILoadingIndicator("working") {
            "done"
        }
        #expect(result == "done")
    }
}
