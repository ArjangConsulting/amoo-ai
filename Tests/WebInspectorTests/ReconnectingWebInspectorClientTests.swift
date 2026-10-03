import Foundation
@testable import WebInspector
import XCTest

/// A channel that never answers, as when webinspectord idles out mid-handshake.
private struct SilentChannel: WebKitRPCChannel {
    func send(selector _: String, argument _: [String: WIRValue]) async throws {}
    func receive(timeout: Duration) async throws -> WIRMessage? {
        try await Task.sleep(for: min(timeout, .milliseconds(20)))
        throw WebInspectorError.timedOut(milliseconds: 0)
    }

    func close() async {}
}

/// A channel whose peer has already hung up.
private struct ClosedChannel: WebKitRPCChannel {
    func send(selector _: String, argument _: [String: WIRValue]) async throws {}
    func receive(timeout _: Duration) async throws -> WIRMessage? {
        nil
    }

    func close() async {}
}

private actor FlakyClient: WebInspectorClient {
    private var failures: Int
    private let error: WebInspectorError
    private(set) var evaluations = 0
    private(set) var closed = false

    init(failures: Int, error: WebInspectorError = .transportUnavailable("webinspectord closed the connection")) {
        self.failures = failures
        self.error = error
    }

    func evaluate(_ request: WebViewEvalRequest) async throws -> WebViewEvalResult {
        evaluations += 1
        if failures > 0 {
            failures -= 1
            throw error
        }
        return WebViewEvalResult(jsonValue: "1", frameURL: nil)
    }

    func dom(_: WebViewDomRequest) async throws -> [WebViewDocument] {
        []
    }

    func close() async {
        closed = true
    }
}

private actor ConnectCounter {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

final class ReconnectingWebInspectorClientTests: XCTestCase {
    /// Regression: a silent handshake surfaced as "timed out after 0ms" and ignored `timeout_ms`.
    func testSilentHandshakeIsATransportFailureNotAZeroMillisecondTimeout() async {
        let client = WebKitWebInspectorClient(
            channel: SilentChannel(),
            bundleID: "com.app",
            handshakeTimeout: .seconds(5)
        )
        do {
            _ = try await client.evaluate(WebViewEvalRequest(expression: "1", timeoutMilliseconds: 150))
            XCTFail("expected a failure")
        } catch let WebInspectorError.transportUnavailable(reason) {
            XCTAssertTrue(reason.contains("150ms"), "the real budget is reported: \(reason)")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testClosedConnectionIsATransportFailure() async {
        let client = WebKitWebInspectorClient(channel: ClosedChannel(), bundleID: "com.app")
        do {
            _ = try await client.evaluate(WebViewEvalRequest(expression: "1"))
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(
                error as? WebInspectorError,
                .transportUnavailable("webinspectord closed the connection")
            )
        }
    }

    func testReconnectsAfterAClosedTransport() async throws {
        let counter = ConnectCounter()
        let client = ReconnectingWebInspectorClient(retryDelay: .milliseconds(10)) {
            let attempt = await counter.next()
            return FlakyClient(failures: attempt < 3 ? 1 : 0)
        }
        let result = try await client.evaluate(WebViewEvalRequest(expression: "1", timeoutMilliseconds: 5000))
        XCTAssertEqual(result.jsonValue, "1")
        let connects = await counter.count
        XCTAssertEqual(connects, 3)
    }

    func testGivesUpWithinTheTimeoutAndReportsAttempts() async {
        let client = ReconnectingWebInspectorClient(retryDelay: .milliseconds(10)) {
            FlakyClient(failures: .max)
        }
        let started = ContinuousClock.now
        do {
            _ = try await client.evaluate(WebViewEvalRequest(expression: "1", timeoutMilliseconds: 200))
            XCTFail("expected a failure")
        } catch let WebInspectorError.transportUnavailable(reason) {
            XCTAssertTrue(reason.contains("gave up after"), reason)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testNonTransportErrorsAreNotRetried() async {
        let counter = ConnectCounter()
        let client = ReconnectingWebInspectorClient(retryDelay: .milliseconds(10)) {
            _ = await counter.next()
            return FlakyClient(failures: 5, error: .timedOut(milliseconds: 1234))
        }
        do {
            _ = try await client.evaluate(WebViewEvalRequest(expression: "slow()", timeoutMilliseconds: 5000))
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? WebInspectorError, .timedOut(milliseconds: 1234))
        }
        let connects = await counter.count
        XCTAssertEqual(connects, 1, "a genuine evaluation timeout must not re-run the expression")
    }
}
