import Foundation
@testable import WebInspector
import XCTest

/// A scripted CDP channel: hands back a canned reply for each `Runtime.evaluate` it sees.
private actor FakeChannel: CDPChannel {
    private var outbox: [Data]
    private(set) var sent: [String] = []

    init(replies: [String]) {
        outbox = replies.map { Data($0.utf8) }
    }

    func send(_ data: Data) async throws {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? Int {
            sent.append(object["method"] as? String ?? "")
            // Stamp the reply with the request id the client is waiting on.
            if !outbox.isEmpty {
                var reply = try JSONSerialization.jsonObject(with: outbox[0]) as? [String: Any] ?? [:]
                reply["id"] = id
                outbox[0] = try JSONSerialization.data(withJSONObject: reply)
            }
        }
    }

    func receive() async throws -> Data {
        guard !outbox.isEmpty else {
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            throw WebInspectorError.protocolError("no more scripted replies")
        }
        return outbox.removeFirst()
    }

    func close() async {}
}

private struct FakeFactory: CDPChannelFactory {
    var targets: String
    var makeChannel: @Sendable () -> FakeChannel

    func targetsJSON(baseURL _: URL) async throws -> Data {
        Data(targets.utf8)
    }

    func openChannel(webSocketURL _: URL) async throws -> any CDPChannel {
        makeChannel()
    }
}

final class CDPWebInspectorClientTests: XCTestCase {
    private let oneTarget = #"[{"id":"a","type":"page","url":"https://e","webSocketDebuggerUrl":"ws://127.0.0.1:9/a"}]"#

    func testEvaluateReturnsJSONSerializedValue() async throws {
        let factory = FakeFactory(targets: oneTarget) {
            FakeChannel(replies: [#"{"result":{"result":{"value":42}}}"#])
        }
        let client = try CDPWebInspectorClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1")), factory: factory)

        let result = try await client.evaluate(WebViewEvalRequest(expression: "6*7"))
        XCTAssertEqual(result.jsonValue, "42")
        XCTAssertFalse(result.isException)
        XCTAssertEqual(result.frameURL, "https://e")
    }

    func testEvaluateSurfacesException() async throws {
        let factory = FakeFactory(targets: oneTarget) {
            FakeChannel(replies: [
                #"{"result":{"exceptionDetails":{"exception":{"description":"ReferenceError: x"}}}}"#
            ])
        }
        let client = try CDPWebInspectorClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1")), factory: factory)

        let result = try await client.evaluate(WebViewEvalRequest(expression: "x"))
        XCTAssertTrue(result.isException)
        XCTAssertTrue(result.jsonValue.contains("ReferenceError"))
    }

    func testDomReturnsOuterHTMLPerTarget() async throws {
        let factory = FakeFactory(targets: oneTarget) {
            FakeChannel(replies: [#"{"result":{"result":{"value":"<html><body>hi</body></html>"}}}"#])
        }
        let client = try CDPWebInspectorClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1")), factory: factory)

        let docs = try await client.dom(WebViewDomRequest(mode: .html))
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs[0].content, "<html><body>hi</body></html>")
        XCTAssertEqual(docs[0].webViewIndex, 0)
    }

    func testNoInspectablePagesThrows() async throws {
        let factory = FakeFactory(targets: "[]") { FakeChannel(replies: []) }
        let client = try CDPWebInspectorClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:1")), factory: factory)

        await XCTAssertThrowsErrorAsync(try await client.evaluate(WebViewEvalRequest(expression: "1"))) { error in
            XCTAssertEqual(error as? WebInspectorError, .noInspectableWebViews(bundleID: nil))
        }
    }

    func testUnconfiguredResolverThrowsNotConfigured() async {
        await XCTAssertThrowsErrorAsync(
            try await UnconfiguredWebInspector().client(platform: .ios, bundleID: nil)
        ) { error in
            XCTAssertEqual(error as? WebInspectorError, .notConfigured)
        }
    }

    func testIOSResolverWithoutEnvThrowsNotImplemented() async {
        let resolver = PlatformWebInspecting(
            shell: NoopShell(),
            factory: FakeFactory(targets: "[]") { FakeChannel(replies: []) },
            environment: [:]
        )
        await XCTAssertThrowsErrorAsync(try await resolver.client(platform: .ios, bundleID: nil)) { error in
            XCTAssertEqual(error as? WebInspectorError, .iosTransportNotImplemented)
        }
    }
}

private struct NoopShell: WebInspectorShell {
    func run(_: [String]) async throws -> WebInspectorShellResult {
        WebInspectorShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ handler: (any Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
