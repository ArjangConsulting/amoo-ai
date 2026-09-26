import Foundation
@testable import WebInspector
import XCTest

/// Scripted `webinspectord`: an app whose page is listed under its WebContent proxy, a modern
/// Target-domain page, and a `Runtime.evaluate` that returns a Promise.
private actor FakeInspector: WebKitRPCChannel {
    private var inbox: [WIRMessage] = []
    private(set) var innerMethods: [String] = []
    private(set) var setupPageApp: String?

    func send(selector: String, argument: [String: WIRValue]) async throws {
        switch selector {
        case "_rpc_getConnectedApplications:":
            inbox.append(WIRMessage(selector: "_rpc_reportConnectedApplicationList:", argument: [
                "WIRApplicationDictionaryKey": .dictionary([
                    "PID:1": .dictionary([
                        "WIRApplicationIdentifierKey": .string("PID:1"),
                        "WIRApplicationBundleIdentifierKey": .string("com.app")
                    ]),
                    "PID:2": .dictionary([
                        "WIRApplicationIdentifierKey": .string("PID:2"),
                        "WIRIsApplicationProxyKey": .bool(true),
                        "WIRHostApplicationIdentifierKey": .string("PID:1")
                    ]),
                    "PID:3": .dictionary([
                        "WIRApplicationIdentifierKey": .string("PID:3"),
                        "WIRApplicationBundleIdentifierKey": .string("com.other")
                    ])
                ])
            ]))
        case "_rpc_forwardGetListing:":
            let app = argument["WIRApplicationIdentifierKey"]?.string ?? ""
            let listing: [String: WIRValue] = app == "PID:2"
                ? ["1": .dictionary([
                    "WIRPageIdentifierKey": .int(1),
                    "WIRTypeKey": .string("WIRTypeWebPage"),
                    "WIRURLKey": .string("https://player/")
                ])]
                : [:]
            inbox.append(WIRMessage(selector: "_rpc_applicationSentListing:", argument: [
                "WIRApplicationIdentifierKey": .string(app), "WIRListingKey": .dictionary(listing)
            ]))
        case "_rpc_forwardSocketSetup:":
            setupPageApp = argument["WIRApplicationIdentifierKey"]?.string
            reply(#"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-1","type":"page"}}}"#)
        case "_rpc_forwardSocketData:":
            guard let data = argument["WIRSocketDataKey"]?.data,
                  let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  outer["method"] as? String == "Target.sendMessageToTarget",
                  let params = outer["params"] as? [String: Any],
                  let text = params["message"] as? String,
                  let inner = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let id = inner["id"] as? Int, let method = inner["method"] as? String
            else { throw WebInspectorError.protocolError("expected a Target-wrapped command") }
            innerMethods.append(method)
            let result = switch method {
            case "Runtime.evaluate": #"{"result":{"type":"object","className":"Promise","objectId":"o1"}}"#
            case "Runtime.awaitPromise": #"{"result":{"type":"object","value":{"pass":true}}}"#
            default: "{}"
            }
            let innerReply = #"{"id":\#(id),"result":\#(result)}"#
            let escaped = try String(bytes: JSONEncoder().encode(innerReply), encoding: .utf8) ?? ""
            reply(
                #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"page-1","message":\#(escaped)}}"#
            )
        default:
            return
        }
    }

    private func reply(_ json: String) {
        inbox.append(WIRMessage(selector: "_rpc_applicationSentData:", argument: [
            "WIRMessageDataKey": .data(Data(json.utf8))
        ]))
    }

    func receive(timeout: Duration) async throws -> WIRMessage? {
        guard inbox.isEmpty else { return inbox.removeFirst() }
        try await Task.sleep(for: min(timeout, .milliseconds(20)))
        throw WebInspectorError.timedOut(milliseconds: 0)
    }

    func close() async {}
}

final class WebKitWebInspectorClientTests: XCTestCase {
    func testEvaluatesThroughTheProxyPageAndAwaitsPromises() async throws {
        let inspector = FakeInspector()
        let client = WebKitWebInspectorClient(channel: inspector, bundleID: "com.app", handshakeTimeout: .seconds(1))

        let result = try await client.evaluate(WebViewEvalRequest(expression: "probe()"))

        XCTAssertEqual(result.jsonValue, #"{"pass":true}"#)
        XCTAssertEqual(result.frameURL, "https://player/")
        XCTAssertFalse(result.isException)
        let setupApp = await inspector.setupPageApp
        XCTAssertEqual(setupApp, "PID:2", "the page lives in the app's WebContent proxy")
        let methods = await inspector.innerMethods
        XCTAssertEqual(Array(methods.prefix(2)), ["Runtime.evaluate", "Runtime.awaitPromise"])
    }

    func testMissingAppIsReportedAsNotRunning() async {
        let client = WebKitWebInspectorClient(
            channel: FakeInspector(),
            bundleID: "com.absent",
            handshakeTimeout: .seconds(1)
        )
        do {
            _ = try await client.evaluate(WebViewEvalRequest(expression: "1"))
            XCTFail("expected appNotRunning")
        } catch {
            XCTAssertEqual(error as? WebInspectorError, .appNotRunning(bundleID: "com.absent"))
        }
    }

    func testPagePickingSkipsBlankAndNonWebTargets() {
        let pages = [
            WIRPage(applicationID: "A", pageID: 1, type: "WIRTypeWebPage", url: "https://real/"),
            WIRPage(applicationID: "A", pageID: 2, type: "WIRTypeJavaScript", url: "https://jsc/"),
            WIRPage(applicationID: "A", pageID: 3, type: "WIRTypeWebPage", url: "about:blank")
        ]
        XCTAssertEqual(WebKitWebInspectorClient.pickPage(pages)?.pageID, 1)
    }

    /// Regression: a timed-out wait cancelled a task blocked on `AsyncStream.next()`, which ends
    /// the stream; every later receive then reported "webinspectord closed the connection".
    func testMessageQueueSurvivesATimedOutWait() async throws {
        let queue = WIRMessageQueue()
        do {
            _ = try await queue.next(timeout: .milliseconds(20))
            XCTFail("expected a timeout")
        } catch {}
        queue.push(WIRMessage(selector: "later", argument: [:]))
        let message = try await queue.next(timeout: .seconds(1))
        XCTAssertEqual(message?.selector, "later")
        queue.finish()
        let closed = try await queue.next(timeout: .seconds(1))
        XCTAssertNil(closed)
    }

    func testBinaryPlistFramingRoundTrips() throws {
        let frame = try WIRCodec.encode(selector: "_rpc_x:", argument: ["k": .bool(true), "n": .int(3)])
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(length, frame.count - 4)
        let decoded = WIRCodec.decode(frame.dropFirst(4))
        XCTAssertEqual(decoded, WIRMessage(selector: "_rpc_x:", argument: ["k": .bool(true), "n": .int(3)]))
    }
}
