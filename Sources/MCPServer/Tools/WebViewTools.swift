/// WebView / DOM introspection. The native accessibility snapshot that `describe_screen` and
/// `find_elements` walk stops at a `WKWebView` / `WebView` boundary — a custom web player with
/// `pointer-events: none` and no ARIA labels is one opaque rectangle to those tools. These reach
/// the web content over a debugging wire protocol instead (see docs/webview-introspection.md).
public enum WebViewTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "webview_eval",
            title: "Evaluate JavaScript in a WebView",
            description: "Run a JavaScript expression against the frontmost app's inspectable"
                + " WebView and return the result JSON-serialized — enough to assert on"
                + " document.querySelector(...), getComputedStyle(...).overflow, a video's"
                + " currentTime, element visibility, etc. Requires the app to enable web debugging"
                + " in its debug build (WKWebView.isInspectable /"
                + " WebView.setWebContentsDebuggingEnabled). Android works today; iOS needs the"
                + " WebKit Remote Inspector bridge (docs/webview-introspection.md).",
            properties: [
                "expression": .init(type: "string", description: "The JavaScript expression to evaluate."),
                "bundle_id": .init(
                    type: "string",
                    description: "App to scope to. Defaults to the current target app."
                ),
                "all_frames": .init(
                    type: "string",
                    description: "'true' to evaluate in every inspectable frame, not just the main one."
                ),
                "timeout_ms": .init(type: "string", description: "Evaluation timeout in ms. Default 5000.")
            ],
            required: ["expression"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "value": .init(type: "string", description: "JSON-serialized result value"),
                    "webview_index": .init(type: "integer", description: "0-based index of the webview it ran in"),
                    "frame_url": .init(type: "string", description: "URL of the frame it ran in, when known"),
                    "is_exception": .init(type: "boolean", description: "True when the expression threw")
                ],
                required: ["value", "webview_index", "is_exception"]
            )
        ),
        ToolDefinition(
            name: "webview_dom",
            title: "Dump WebView DOM",
            description: "Return each inspectable WebView's DOM — full document.documentElement"
                + ".outerHTML (mode=html, default) or a trimmed {tag, role, aria, text, bbox,"
                + " hidden} tree (mode=a11y). Same debug-build requirement as webview_eval.",
            properties: [
                "bundle_id": .init(type: "string", description: "App to scope to. Defaults to the current target app."),
                "mode": .init(type: "string", description: "'html' (default) or 'a11y'."),
                "max_bytes": .init(type: "string", description: "Optional cap on each document's returned length.")
            ],
            outputSchema: ToolOutputSchema(
                properties: [
                    "documents": .init(
                        type: "array",
                        description: "One entry per inspectable WebView",
                        items: .object(
                            properties: [
                                "webview_index": .init(type: "integer", description: "0-based index"),
                                "frame_url": .init(type: "string", description: "Frame URL when known"),
                                "content": .init(type: "string", description: "outerHTML or the JSON a11y tree")
                            ],
                            required: ["webview_index", "content"]
                        )
                    )
                ],
                required: ["documents"]
            )
        )
    ]
}
