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

- **Android.** `WebView.setWebContentsDebuggingEnabled(true)` (apps typically gate this on
  `BuildConfig.DEBUG`) exposes the **Chrome DevTools Protocol** on the abstract socket
  `localabstract:webview_devtools_remote_<pid>`. `PlatformWebInspecting` — with every `adb` call
  scoped to the target serial — checks the app is running (`pidof`), picks the socket owned by
  that pid, forwards a fresh local port to it (removed again on close; forwards left by dead
  WebViews are swept), fetches `GET /json`, ranks the attached/visible page above Android's
  pre-warmed empty one, and runs `Runtime.evaluate` (`awaitPromise: true`) over a WebSocket. CDP
  accepts **text frames only** — a binary frame makes WebView's Chrome drop the socket, which
  `URLSession` reports as POSIX 57 "Socket is not connected".

- **iOS Simulator.** Each booted simulator runs its own `webinspectord`, whose socket its launchd
  publishes as `RWI_LISTEN_SOCKET` (`xcrun simctl getenv <udid> RWI_LISTEN_SOCKET`).
  `WebKitWebInspectorClient` speaks the Remote Inspector protocol natively — length-prefixed
  binary plists: `_rpc_reportIdentifier:`, `_rpc_getConnectedApplications:`,
  `_rpc_forwardGetListing:` for the app and the `WebContent` proxies it hosts,
  `_rpc_forwardSocketSetup:`, then Web Inspector JSON through `_rpc_forwardSocketData:`, wrapped
  in `Target.sendMessageToTarget` once `Target.targetCreated` names the page. WebKit's
  `Runtime.evaluate` has no `awaitPromise`, so a Promise result is resolved with
  `Runtime.awaitPromise`, and any other object is read with `Runtime.callFunctionOn` (never by
  re-evaluating the expression). The app's debug build must set `WKWebView.isInspectable = true`.

- **iOS physical devices** need a usbmux/lockdown transport that is not implemented. Set
  `AMOO_IOS_WEBINSPECTOR_URL` to a CDP-compatible endpoint (e.g.
  [`ios-webkit-debug-proxy`](https://github.com/google/ios-webkit-debug-proxy),
  `ios_webkit_debug_proxy -F -c <udid>:9222`) and `CDPWebInspectorClient` handles it; the
  variable also overrides the simulator transport.

`amoo probe run` builds on the same clients: it evaluates checked-in probe files in order and
judges each by its `{probe, pass, details}` result (see `amoo probe run --help`).

## Follow-up work

1. **Native transport for physical iOS devices** (usbmux → `com.apple.webinspector` lockdown
   service), reusing `WebKitWebInspectorClient` over a different `WebKitRPCChannel`.
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
| `Sources/WebInspector/PlatformWebInspecting.swift` | Platform → endpoint wiring (Android `adb`; iOS simulator socket or env opt-in). |
| `Sources/WebInspector/WebKitInspectorConnection.swift` | Remote Inspector framing (binary plist), unix-socket channel, timeout-safe message queue. |
| `Sources/WebInspector/WebKitWebInspectorClient.swift` | `WebInspectorClient` over the WebKit Remote Inspector (iOS Simulator). |
| `Sources/MCPServer/Tools/WebViewTools.swift` | The two MCP tool definitions. |
| `Sources/MCPServer/ToolExecutor+WebView.swift` | Handlers mapping tool args → `WebInspectorClient` → `ToolResult`. |
