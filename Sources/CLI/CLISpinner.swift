import SwiftyTerminal

// SwiftyTerminal's `withSpinner` takes `isolation: isolated (any Actor)? = #isolation` and
// `rethrows`. Release builds from Xcode 26.6 (Swift 6.3) abort inside it with "freed pointer was
// not the last allocation", which failed the release smoke gate on `amoo device current_app`.
// These keep the shape of the pre-SwiftyTerminal helper, which those builds ran cleanly, and
// `CLISpinnerUsageTests` keeps `Sources/` off the upstream function.

/// Runs `operation` with a SwiftyTerminal spinner on stderr, erasing it afterwards.
///
/// - Parameters:
///   - message: Text displayed beside the spinner.
///   - operation: The work to perform. Its value or error is returned after the spinner stops.
func withCLISpinner<T>(
    _ message: String,
    operation: () async throws -> T
) async throws -> T {
    let spinner = Spinner(message)
    await spinner.start()
    do {
        let value = try await operation()
        await spinner.stop()
        return value
    } catch {
        await spinner.stop()
        throw error
    }
}

/// Runs non-throwing `operation` with a SwiftyTerminal spinner on stderr, erasing it afterwards.
///
/// - Parameters:
///   - message: Text displayed beside the spinner.
///   - operation: The work to perform. Its value is returned after the spinner stops.
func withCLISpinner<T>(
    _ message: String,
    operation: () async -> T
) async -> T {
    let spinner = Spinner(message)
    await spinner.start()
    let value = await operation()
    await spinner.stop()
    return value
}
