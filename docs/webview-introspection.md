# WebView / DOM introspection (`webview_eval`, `webview_dom`)

`describe_screen` / `find_elements` / `find_element_by_description` all walk the **native
accessibility snapshot**. That walk stops at a `WKWebView` (iOS) / `WebView` (Android) boundary:
anything rendered inside — a custom video player with `pointer-events: none` on the `<iframe>` and
no ARIA labels on the overlay — is one opaque rectangle. Every "is the web UI in the right state"
check then degrades to eyeballing a screenshot.

`webview_eval` and `webview_dom` reach the web content directly:

| Tool | Does |
| --- | --- |
| `webview_eval expression=<js> [bundle_id] [all_frames] [timeout_ms]` | Evaluates a JS expression in the inspectable WebView and returns the result **JSON-serialized** (`42`, `"hidden"`, `{"x":1}`), plus which webview/frame it ran in and whether it threw. Enough to assert on `document.querySelector(...)`, `getComputedStyle(...).overflow`, a video's `currentTime`, element visibility. |
| `webview_dom [bundle_id] [mode=html\|a11y] [max_bytes]` | Returns each inspectable WebView's DOM — full `document.documentElement.outerHTML` (`mode=html`, default) or a trimmed `{tag, role, aria, text, bbox, hidden}` tree (`mode=a11y`). |

Both are exposed on the CLI (`amoo device webview_eval …`) and MCP (`webview_eval`), scoped by
bundle id like the other element tools.

## Why this is a host-side transport, not a companion RPC

The XCUITest / UiAutomator companion runs **out-of-process** from the app under test, so it cannot
call `WKWebView.evaluateJavaScript` / `WebView.evaluateJavascript` on the app's webview. The only
way in is a **debugging wire protocol**, driven from the host:

- **Android — working today.** `WebView.setWebContentsDebuggingEnabled(true)` (apps typically gate
  this on `BuildConfig.DEBUG`) exposes the **Chrome DevTools Protocol** on the abstract socket
  `localabstract:webview_devtools_remote_<pid>`. `PlatformWebInspecting` finds it in
  `/proc/net/unix` via `adb shell`, `adb forward tcp:0 localabstract:<name>`, then the
  `CDPWebInspectorClient` fetches `GET /json`, connects the target's `webSocketDebuggerUrl`, and
  runs `Runtime.evaluate` / `DOM.*`.

- **iOS — not wired up yet.** The equivalent is the **WebKit Remote Inspector**. It needs no in-app
  SDK on the Simulator or on a debug build where `WKWebView.isInspectable == true` (iOS 16.4+), but
  the transport is the `webinspectord` bplist protocol, not CDP. Until that lands,
  `PlatformWebInspecting` throws `WebInspectorError.iosTransportNotImplemented`. **Early opt-in:**
  set `AMOO_IOS_WEBINSPECTOR_URL` to a CDP-compatible endpoint — e.g. a running
  [`ios-webkit-debug-proxy`](https://github.com/google/ios-webkit-debug-proxy)
  (`brew install ios-webkit-debug-proxy`; `ios_webkit_debug_proxy -F -c <udid>:9222`) — and the
  same `CDPWebInspectorClient` handles it.

## Follow-up work

1. **Native `webinspectord` transport for iOS Simulator + device.** Speak the Remote Inspector
   protocol (`_rpc_reportIdentifier`, `_rpc_getConnectedApplications`,
   `_rpc_forwardSocketSetup`, then `Runtime.evaluate` in the auto-created inspector session), so no
   external proxy is required. Slot it behind `WebInspecting` — callers do not change.
2. **Cross-origin frames.** YouTube's player is a cross-origin `<iframe>`; `Runtime.evaluate` runs
   per execution context. `all_frames=true` currently returns one document per DevTools *target*;
   full frame coverage needs `Page.getFrameTree` + per-frame execution-context ids.
3. **Integration test against a live fixture.** A tiny `WKWebView`/`WebView` host loading fixture
   HTML with a known element count and `#player-container { overflow: hidden }`, asserting
   `webview_eval expression='document.querySelectorAll("*").length'` returns the known number and
   `getComputedStyle(...).overflow` returns `"hidden"`. `XCTSkip` when no sim / no proxy.

## Code map

| File | Role |
| --- | --- |
| `Sources/WebInspector/WebInspectorClient.swift` | `WebInspectorClient` / `WebInspecting` protocols, request/result models, `WebInspectorError`, `UnconfiguredWebInspector` (the default). |
| `Sources/WebInspector/ChromeDevToolsProtocol.swift` | CDP request/message/target envelope + a minimal `JSONValue`. |
| `Sources/WebInspector/CDPWebInspectorClient.swift` | `WebInspectorClient` over CDP, with an injectable `CDPChannelFactory`. |
| `Sources/WebInspector/URLSessionCDPChannel.swift` | Real transport: `URLSession` for `/json`, `URLSessionWebSocketTask` for the debugger socket. |
| `Sources/WebInspector/PlatformWebInspecting.swift` | Platform → endpoint wiring (Android `adb`; iOS env opt-in / not-implemented). |
| `Sources/MCPServer/Tools/WebViewTools.swift` | The two MCP tool definitions. |
| `Sources/MCPServer/ToolExecutor+WebView.swift` | Handlers mapping tool args → `WebInspectorClient` → `ToolResult`. |
