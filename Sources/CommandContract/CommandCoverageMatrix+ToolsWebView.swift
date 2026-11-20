import AmooCore
import Foundation

public extension CommandCoverageMatrix {
    /// WebView / DOM introspection tools. Split from `+Tools.swift` to keep that file under the
    /// length limit.
    static let toolWebViewCommands: [CommandCoverage] = [
        .init(
            name: "webview_eval",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "a JavaScript expression evaluates inside the app's WebView and returns JSON"
        ),
        .init(
            name: "webview_dom",
            channel: .tool,
            kind: .deterministic,
            releaseTier: .informational,
            platforms: allPlatforms,
            fixtureScreen: .home,
            expectedAssertion: "each inspectable WebView's outerHTML (or trimmed tree) is returned"
        )
    ]
}
