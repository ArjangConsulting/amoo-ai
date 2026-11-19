/// Ahead-of-time compilation of an installed app, where the platform has it (Android's ART).
///
/// An app installed by `adb install` can be left running from its APK, inflating every dex file
/// on the main thread at its first cold start; on a loaded emulator that start can outlast the
/// platform's startup deadline and be killed. Compiling right after install moves that cost out of
/// the first launch. It is opt-in: on a slow emulator it takes tens of seconds or minutes.
public protocol AppCompiling: Sendable {
    /// Compiles `appID` with the compiler filter `mode` (`verify`, `speed-profile`, `speed`) and
    /// returns the tool's output.
    func compileApp(appID: String, mode: String) async throws -> String
}
