import Foundation

/// A bidirectional CDP message channel (one WebSocket). Injectable so the client is unit-testable
/// without a live browser.
public protocol CDPChannel: Sendable {
    func send(_ data: Data) async throws
    /// The next inbound text frame.
    func receive() async throws -> Data
    func close() async
}

/// Opens a `CDPChannel` to a devtools target discovered from a `/json` base URL.
public protocol CDPChannelFactory: Sendable {
    /// `baseURL` is `http://<host>:<port>` — the client fetches `/json` from it and connects.
    func targetsJSON(baseURL: URL) async throws -> Data
    func openChannel(webSocketURL: URL) async throws -> any CDPChannel
}

/// `WebInspectorClient` over the Chrome DevTools Protocol. Used directly for Android; and for iOS
/// once the `ios-webkit-debug-proxy` bridge is wired up (`docs/webview-introspection.md`).
public actor CDPWebInspectorClient: WebInspectorClient {
    private let baseURL: URL
    private let factory: any CDPChannelFactory
    private let bundleID: String?
    private var nextID = 1

    public init(baseURL: URL, factory: any CDPChannelFactory, bundleID: String? = nil) {
        self.baseURL = baseURL
        self.factory = factory
        self.bundleID = bundleID
    }

    public func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult {
        let targets = try await inspectablePages()
        guard let picked = pick(targets, allFrames: request.allFrames).first else {
            throw WebInspectorError.noInspectableWebViews(bundleID: bundleID)
        }
        let channel = try await open(picked)
        defer { Task { await channel.close() } }

        let result = try await call(
            channel,
            method: "Runtime.evaluate",
            params: [
                "expression": .string(request.expression),
                "returnByValue": .bool(true),
                "awaitPromise": .bool(true)
            ],
            timeoutMilliseconds: request.timeoutMilliseconds
        )
        if let exception = result["exceptionDetails"] {
            let text = exception["exception"]?["description"]?.jsonString
                ?? exception["text"]?.jsonString
                ?? "\"exception\""
            return WebViewEvalResult(jsonValue: text, frameURL: picked.url, isException: true)
        }
        let value = result["result"]?["value"] ?? .null
        return WebViewEvalResult(jsonValue: value.jsonString, frameURL: picked.url)
    }

    public func dom(_ request: WebViewDomRequest) async throws -> [WebViewDocument] {
        let targets = try await inspectablePages()
        var documents: [WebViewDocument] = []
        for (index, target) in targets.enumerated() {
            let channel = try await open(target)
            let expression = request.mode == .html
                ? "document.documentElement.outerHTML"
                : Self.a11yTreeScript
            let result = try await call(
                channel,
                method: "Runtime.evaluate",
                params: ["expression": .string(expression), "returnByValue": .bool(true)],
                timeoutMilliseconds: 5000
            )
            await channel.close()
            var content = result["result"]?["value"].flatMap { value -> String? in
                if case let .string(string) = value {
                    return string
                }
                return value.jsonString
            } ?? ""
            if let cap = request.maxBytes, content.utf8.count > cap {
                content = String(content.prefix(cap))
            }
            documents.append(WebViewDocument(webViewIndex: index, frameURL: target.url, content: content))
        }
        return documents
    }

    // MARK: - Internals

    private func inspectablePages() async throws -> [CDP.Target] {
        let data = try await factory.targetsJSON(baseURL: baseURL)
        let pages = try CDP.decodeTargets(data).filter(\.isInspectablePage)
        guard !pages.isEmpty else { throw WebInspectorError.noInspectableWebViews(bundleID: bundleID) }
        return pages
    }

    private func pick(_ targets: [CDP.Target], allFrames: Bool) -> [CDP.Target] {
        guard let first = targets.first else { return [] }
        return allFrames ? targets : [first]
    }

    private func open(_ target: CDP.Target) async throws -> any CDPChannel {
        guard let raw = target.webSocketDebuggerUrl, let url = URL(string: raw) else {
            throw WebInspectorError.protocolError("target \(target.id) has no webSocketDebuggerUrl")
        }
        return try await factory.openChannel(webSocketURL: url)
    }

    private func call(
        _ channel: any CDPChannel,
        method: String,
        params: [String: JSONValue],
        timeoutMilliseconds: Int
    ) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        try await channel.send(CDP.encode(CDP.Request(id: id, method: method, params: params)))

        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask {
                while true {
                    let message = try await CDP.decode(channel.receive())
                    guard message.id == id else { continue }
                    if let error = message.error {
                        throw WebInspectorError.protocolError("\(error.code): \(error.message)")
                    }
                    return message.result ?? .null
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                throw WebInspectorError.timedOut(milliseconds: timeoutMilliseconds)
            }
            guard let result = try await group.next() else {
                throw WebInspectorError.protocolError("no CDP response")
            }
            group.cancelAll()
            return result
        }
    }

    /// Compact DOM walk producing `{tag, role, aria, text, bbox, hidden}` nodes.
    private static let a11yTreeScript = """
    (function () {
      function walk(el) {
        var r = el.getBoundingClientRect();
        var cs = getComputedStyle(el);
        return {
          tag: el.tagName.toLowerCase(),
          role: el.getAttribute('role') || null,
          aria: el.getAttribute('aria-label') || null,
          text: (el.childElementCount === 0 ? (el.textContent || '').trim().slice(0, 120) : ''),
          bbox: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
          hidden: cs.visibility === 'hidden' || cs.display === 'none' || r.width === 0,
          children: Array.prototype.slice.call(el.children).map(walk)
        };
      }
      return JSON.stringify(walk(document.documentElement));
    })()
    """
}
