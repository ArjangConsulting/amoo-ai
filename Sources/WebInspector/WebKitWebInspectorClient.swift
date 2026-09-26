import Foundation

/// A page the Remote Inspector lists for an application.
struct WIRPage: Equatable {
    var applicationID: String
    var pageID: Int
    var type: String
    var url: String?
    var title: String?

    /// Web content, not a JSContext, service worker or automation session.
    var isWebPage: Bool {
        let lowered = type.lowercased()
        return (lowered.contains("web") || lowered.contains("page"))
            && !lowered.contains("javascript") && !lowered.contains("serviceworker")
            && !lowered.contains("automation") && !lowered.contains("itml")
    }
}

/// An application the Remote Inspector reports.
struct WIRApplication: Equatable {
    var id: String
    var bundleID: String?
    var isProxy: Bool
    var hostID: String?

    init?(_ value: [String: WIRValue]) {
        guard let id = value["WIRApplicationIdentifierKey"]?.string else { return nil }
        self.id = id
        bundleID = value["WIRApplicationBundleIdentifierKey"]?.string
        isProxy = value["WIRIsApplicationProxyKey"]?.bool ?? false
        hostID = value["WIRHostApplicationIdentifierKey"]?.string
    }
}

/// `WebInspectorClient` over the WebKit Remote Inspector (`webinspectord`), for iOS Simulator
/// `WKWebView`s with `isInspectable` enabled.
///
/// Handshake: report an identifier, list connected applications, pick the app (plus the
/// `com.apple.WebKit.WebContent` proxies it hosts), list their pages, attach to one with
/// `_rpc_forwardSocketSetup:`, then exchange Web Inspector JSON through
/// `_rpc_forwardSocketData:` / `_rpc_applicationSentData:`. Modern WebKit multiplexes a page's
/// inspector through the `Target` domain, so commands are wrapped in
/// `Target.sendMessageToTarget` once a `Target.targetCreated` event names the page target.
public actor WebKitWebInspectorClient: WebInspectorClient {
    private let channel: any WebKitRPCChannel
    private let bundleID: String?
    private let connectionID = UUID().uuidString
    private let senderID = UUID().uuidString
    private var applications: [String: WIRApplication] = [:]
    private var pages: [WIRPage] = []
    private var attached: WIRPage?
    private var targetID: String?
    private var nextID = 1
    /// Replies that arrived while waiting for something else, keyed by command id.
    private var replies: [Int: CDP.Message] = [:]
    private let handshakeTimeout: Duration

    public init(channel: any WebKitRPCChannel, bundleID: String?, handshakeTimeout: Duration = .seconds(5)) {
        self.channel = channel
        self.bundleID = bundleID
        self.handshakeTimeout = handshakeTimeout
    }

    public func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult {
        try await attachIfNeeded()
        let page = attached
        let timeout = Duration.milliseconds(request.timeoutMilliseconds)
        let evaluated = try await command(
            "Runtime.evaluate",
            ["expression": .string(request.expression), "objectGroup": .string("amoo"), "returnByValue": .bool(false)],
            timeout: timeout
        )
        var result = evaluated["result"] ?? .null
        var thrown = evaluated["wasThrown"] == .bool(true)

        if !thrown, let objectID = result["objectId"]?.stringValue {
            let resolved = if result["className"]?.stringValue == "Promise" {
                try await command(
                    "Runtime.awaitPromise",
                    ["promiseObjectId": .string(objectID), "returnByValue": .bool(true)],
                    timeout: timeout
                )
            } else {
                // Fetch the value of the object already produced — re-evaluating would re-run
                // the expression's side effects.
                try await command(
                    "Runtime.callFunctionOn",
                    [
                        "objectId": .string(objectID),
                        "functionDeclaration": .string("function() { return this; }"),
                        "returnByValue": .bool(true)
                    ],
                    timeout: timeout
                )
            }
            result = resolved["result"] ?? .null
            thrown = resolved["wasThrown"] == .bool(true)
        }
        _ = try? await command("Runtime.releaseObjectGroup", ["objectGroup": .string("amoo")], timeout: .seconds(2))

        if thrown {
            let text = result["description"]?.jsonString ?? result["value"]?.jsonString ?? "\"exception\""
            return WebViewEvalResult(jsonValue: text, frameURL: page?.url, isException: true)
        }
        let value = result["value"] ?? .null
        return WebViewEvalResult(jsonValue: value.jsonString, frameURL: page?.url)
    }

    public func dom(_ request: WebViewDomRequest) async throws -> [WebViewDocument] {
        let expression = request.mode == .html
            ? "document.documentElement.outerHTML"
            : "JSON.stringify((function walk(el){var r=el.getBoundingClientRect();return {tag:el.tagName.toLowerCase(),"
            + "role:el.getAttribute('role'),aria:el.getAttribute('aria-label'),text:(el.childElementCount===0?"
            + "(el.textContent||'').trim().slice(0,120):''),bbox:[r.x,r.y,r.width,r.height].map(Math.round),"
            + "children:Array.prototype.map.call(el.children,walk)}})(document.documentElement))"
        let result = try await evaluate(WebViewEvalRequest(expression: expression, bundleID: request.bundleID))
        var content = (try? JSONDecoder().decode(String.self, from: Data(result.jsonValue.utf8))) ?? result.jsonValue
        if let cap = request.maxBytes, content.utf8.count > cap {
            content = String(content.prefix(cap))
        }
        return [WebViewDocument(webViewIndex: 0, frameURL: result.frameURL, content: content)]
    }

    public func close() async {
        if let page = attached {
            try? await channel.send(selector: "_rpc_forwardDidClose:", argument: pageArgument(page))
        }
        await channel.close()
    }

    // MARK: - Handshake

    private func attachIfNeeded() async throws {
        guard attached == nil else { return }
        let connection = ["WIRConnectionIdentifierKey": WIRValue.string(connectionID)]
        try await channel.send(selector: "_rpc_reportIdentifier:", argument: connection)
        try await channel.send(selector: "_rpc_getConnectedApplications:", argument: connection)
        try await pump(until: { $0.applications.isEmpty == false }, timeout: handshakeTimeout)

        let candidates = Self.inspectableApplications(Array(applications.values), bundleID: bundleID)
        guard !candidates.isEmpty else {
            throw bundleID.map { WebInspectorError.appNotRunning(bundleID: $0) }
                ?? WebInspectorError.noInspectableWebViews(bundleID: nil)
        }
        for application in candidates {
            try await channel.send(
                selector: "_rpc_forwardGetListing:",
                argument: connection.merging(["WIRApplicationIdentifierKey": .string(application.id)]) { $1 }
            )
        }
        // Listings arrive one message per application; give them the handshake budget.
        try? await pump(until: { $0.pages.contains(where: \.isWebPage) }, timeout: handshakeTimeout)
        try? await pump(until: { _ in false }, timeout: .milliseconds(300))

        guard let page = Self.pickPage(pages) else {
            throw WebInspectorError.noInspectableWebViews(bundleID: bundleID)
        }
        attached = page
        var setup = pageArgument(page)
        setup["WIRAutomaticallyPause"] = .bool(false)
        try await channel.send(selector: "_rpc_forwardSocketSetup:", argument: setup)
        // Modern WebKit announces the page target right away; older builds talk directly.
        try? await pump(until: { $0.targetID != nil }, timeout: .seconds(2))
    }

    private func pageArgument(_ page: WIRPage) -> [String: WIRValue] {
        [
            "WIRConnectionIdentifierKey": .string(connectionID),
            "WIRApplicationIdentifierKey": .string(page.applicationID),
            "WIRPageIdentifierKey": .int(page.pageID),
            "WIRSenderKey": .string(senderID)
        ]
    }

    /// The app itself plus the WebContent proxies it hosts (where its pages are listed).
    static func inspectableApplications(_ all: [WIRApplication], bundleID: String?) -> [WIRApplication] {
        let hosts = all.filter { !$0.isProxy && (bundleID == nil || $0.bundleID == bundleID) }
        let hostIDs = Set(hosts.map(\.id))
        let proxies = all.filter { $0.isProxy && $0.hostID.map(hostIDs.contains) == true }
        return hosts + proxies
    }

    /// The web page most likely on screen: skip blank documents, prefer the most recent listing.
    static func pickPage(_ pages: [WIRPage]) -> WIRPage? {
        let web = pages.filter(\.isWebPage)
        return web.last { page in
            guard let url = page.url, !url.isEmpty else { return false }
            return url != "about:blank"
        } ?? web.last
    }

    // MARK: - Messaging

    private func command(_ method: String, _ params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let inner = try CDP.encode(CDP.Request(id: id, method: method, params: params))
        let outgoing: Data
        if let targetID {
            let wrapperID = nextID
            nextID += 1
            outgoing = try CDP.encode(CDP.Request(
                id: wrapperID,
                method: "Target.sendMessageToTarget",
                params: [
                    "targetId": .string(targetID),
                    "message": .string(String(bytes: inner, encoding: .utf8) ?? "")
                ]
            ))
        } else {
            outgoing = inner
        }
        guard let page = attached else { throw WebInspectorError.noInspectableWebViews(bundleID: bundleID) }
        var argument = pageArgument(page)
        argument["WIRSocketDataKey"] = .data(outgoing)
        try await channel.send(selector: "_rpc_forwardSocketData:", argument: argument)

        do {
            try await pump(until: { $0.replies[id] != nil }, timeout: timeout)
        } catch WebInspectorError.timedOut {
            throw WebInspectorError.timedOut(milliseconds: Int(timeout.components.seconds * 1000
                    + timeout.components.attoseconds / 1_000_000_000_000_000))
        }
        guard let reply = replies.removeValue(forKey: id) else {
            throw WebInspectorError.protocolError("no reply to \(method)")
        }
        if let error = reply.error {
            throw WebInspectorError.protocolError("\(method): \(error.message)")
        }
        return reply.result ?? .null
    }

    /// Reads messages until `condition` holds, or throws `.timedOut` after `timeout`.
    private func pump(until condition: (isolated WebKitWebInspectorClient) -> Bool, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(self) {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw WebInspectorError.timedOut(milliseconds: 0) }
            let message = try await channel.receive(timeout: remaining)
            guard let message else {
                throw WebInspectorError.transportUnavailable("webinspectord closed the connection")
            }
            handle(message)
        }
    }

    private func handle(_ message: WIRMessage) {
        switch message.selector {
        case "_rpc_reportConnectedApplicationList:":
            for value in message.argument["WIRApplicationDictionaryKey"]?.dictionary?.values ?? [:].values {
                if let app = value.dictionary.flatMap(WIRApplication.init) {
                    applications[app.id] = app
                }
            }
        case "_rpc_applicationConnected:", "_rpc_applicationUpdated:":
            if let app = WIRApplication(message.argument) {
                applications[app.id] = app
            }
        case "_rpc_applicationSentListing:":
            recordListing(message.argument)
        case "_rpc_applicationSentData:":
            guard let data = message.argument["WIRMessageDataKey"]?.data else { return }
            handleInspectorMessage(data)
        default:
            return
        }
    }

    private func recordListing(_ argument: [String: WIRValue]) {
        guard let appID = argument["WIRApplicationIdentifierKey"]?.string else { return }
        pages.removeAll { $0.applicationID == appID }
        for value in argument["WIRListingKey"]?.dictionary?.values ?? [:].values {
            guard let listing = value.dictionary, let pageID = listing["WIRPageIdentifierKey"]?.int else { continue }
            pages.append(WIRPage(
                applicationID: appID,
                pageID: pageID,
                type: listing["WIRTypeKey"]?.string ?? "WIRTypeWeb",
                url: listing["WIRURLKey"]?.string,
                title: listing["WIRTitleKey"]?.string
            ))
        }
        pages.sort { ($0.applicationID, $0.pageID) < ($1.applicationID, $1.pageID) }
    }

    private func handleInspectorMessage(_ data: Data) {
        guard let message = try? CDP.decode(data) else { return }
        if let id = message.id {
            replies[id] = message
            return
        }
        switch message.method {
        case "Target.targetCreated":
            let info = message.params?["targetInfo"]
            if info?["type"]?.stringValue == "page", info?["isProvisional"] != .bool(true) {
                targetID = info?["targetId"]?.stringValue
            }
        case "Target.didCommitProvisionalTarget":
            targetID = message.params?["newTargetId"]?.stringValue ?? targetID
        case "Target.dispatchMessageFromTarget":
            if let inner = message.params?["message"]?.stringValue {
                handleInspectorMessage(Data(inner.utf8))
            }
        default:
            return
        }
    }
}

extension JSONValue {
    var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}
