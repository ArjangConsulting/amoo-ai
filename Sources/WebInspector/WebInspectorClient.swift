import Foundation

/// Reads state out of a `WKWebView` (iOS) / `WebView` (Android) that the native accessibility
/// snapshot cannot see — a custom video player with `pointer-events: none` and no ARIA labels
/// surfaces to `describe_screen` / `find_elements` as one opaque rectangle.
///
/// The companion runs out-of-process and cannot call `evaluateJavaScript` on the app's webview,
/// so every implementation reaches the web content over a debugging wire protocol
/// (Chrome DevTools Protocol on Android; the WebKit Remote Inspector on iOS) — see
/// `docs/webview-introspection.md`.
public protocol WebInspectorClient: Sendable {
    /// Evaluate a JavaScript expression in a web document and return its JSON-serialized value.
    func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult

    /// Dump each matching document's DOM (full `outerHTML` or a trimmed a11y-ish tree).
    func dom(_ request: WebViewDomRequest) async throws -> [WebViewDocument]
}

/// Resolves a `WebInspectorClient` for a given platform + app. Absent by default: the webview
/// tools then report "not configured" rather than guessing at a transport.
public protocol WebInspecting: Sendable {
    func client(platform: WebInspectorPlatform, bundleID: String?) async throws -> any WebInspectorClient
}

public enum WebInspectorPlatform: String, Sendable {
    case ios
    case android
}

// MARK: - Requests / results

public struct WebViewEvalRequest: Sendable, Equatable {
    public var expression: String
    public var bundleID: String?
    public var allFrames: Bool
    public var timeoutMilliseconds: Int

    public init(
        expression: String,
        bundleID: String? = nil,
        allFrames: Bool = false,
        timeoutMilliseconds: Int = 5000
    ) {
        self.expression = expression
        self.bundleID = bundleID
        self.allFrames = allFrames
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public struct WebViewEvalResult: Sendable, Equatable {
    /// The result value, already JSON-serialized (e.g. `"42"`, `"\"hidden\""`, `"{\"x\":1}"`).
    public var jsonValue: String
    /// Which webview/frame it ran in (0-based), for the multi-webview case.
    public var webViewIndex: Int
    public var frameURL: String?
    /// True when the expression threw; `jsonValue` then holds the exception text.
    public var isException: Bool

    public init(jsonValue: String, webViewIndex: Int = 0, frameURL: String? = nil, isException: Bool = false) {
        self.jsonValue = jsonValue
        self.webViewIndex = webViewIndex
        self.frameURL = frameURL
        self.isException = isException
    }
}

public struct WebViewDomRequest: Sendable, Equatable {
    public enum Mode: String, Sendable {
        /// `document.documentElement.outerHTML`.
        case html
        /// A trimmed `{tag, role, aria, text, bbox, hidden}` tree.
        case a11y
    }

    public var bundleID: String?
    public var mode: Mode
    public var maxBytes: Int?

    public init(bundleID: String? = nil, mode: Mode = .html, maxBytes: Int? = nil) {
        self.bundleID = bundleID
        self.mode = mode
        self.maxBytes = maxBytes
    }
}

public struct WebViewDocument: Sendable, Equatable {
    public var webViewIndex: Int
    public var frameURL: String?
    /// `outerHTML` for `.html`; a JSON string of the trimmed tree for `.a11y`.
    public var content: String

    public init(webViewIndex: Int, frameURL: String? = nil, content: String) {
        self.webViewIndex = webViewIndex
        self.frameURL = frameURL
        self.content = content
    }
}

// MARK: - Errors

public enum WebInspectorError: Error, CustomStringConvertible, Equatable {
    case notConfigured
    case noInspectableWebViews(bundleID: String?)
    case transportUnavailable(String)
    case iosTransportNotImplemented
    case protocolError(String)
    case timedOut(milliseconds: Int)

    public var description: String {
        switch self {
        case .notConfigured:
            "WebView introspection is not configured for this server. See docs/webview-introspection.md."
        case let .noInspectableWebViews(bundleID):
            "No inspectable WebView found"
                + (bundleID.map { " for \($0)" } ?? "")
                + ". The app must enable web debugging (WKWebView.isInspectable / "
                + "WebView.setWebContentsDebuggingEnabled) in its debug build."
        case let .transportUnavailable(reason):
            "WebView debugging transport unavailable: \(reason)"
        case .iosTransportNotImplemented:
            "iOS WebView introspection needs the WebKit Remote Inspector transport, which is not "
                + "wired up yet. Track it in docs/webview-introspection.md; Android works today."
        case let .protocolError(message):
            "WebView debugging protocol error: \(message)"
        case let .timedOut(milliseconds):
            "WebView evaluation timed out after \(milliseconds)ms."
        }
    }
}

/// The default: no transport wired in. `webview_eval` / `webview_dom` then return
/// `WebInspectorError.notConfigured` instead of guessing.
public struct UnconfiguredWebInspector: WebInspecting {
    public init() {}

    public func client(
        platform _: WebInspectorPlatform,
        bundleID _: String?
    ) async throws -> any WebInspectorClient {
        throw WebInspectorError.notConfigured
    }
}
