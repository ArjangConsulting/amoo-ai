import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import WebInspector
import XCTest

private struct StubInspector: WebInspecting {
    var evalResult: WebViewEvalResult?
    var documents: [WebViewDocument] = []
    var failDom = false
    var closeTracker: CloseTracker?

    func client(
        platform _: WebInspectorPlatform,
        bundleID: String?,
        deviceID _: String?
    ) async throws -> any WebInspectorClient {
        StubClient(
            evalResult: evalResult,
            documents: documents,
            bundleID: bundleID,
            failDom: failDom,
            closeTracker: closeTracker
        )
    }
}

private struct StubClient: WebInspectorClient {
    var evalResult: WebViewEvalResult?
    var documents: [WebViewDocument]
    var bundleID: String?
    var failDom: Bool
    var closeTracker: CloseTracker?

    func evaluate(_: WebViewEvalRequest) async throws -> WebViewEvalResult {
        guard let evalResult else { throw WebInspectorError.noInspectableWebViews(bundleID: bundleID) }
        return evalResult
    }

    func dom(_: WebViewDomRequest) async throws -> [WebViewDocument] {
        if failDom {
            throw WebInspectorError.noInspectableWebViews(bundleID: bundleID)
        }
        return documents
    }

    func close() async {
        await closeTracker?.recordClose()
    }
}

private actor CloseTracker {
    var count = 0

    func recordClose() {
        count += 1
    }
}

final class WebViewToolsTests: XCTestCase {
    func testInspectorClosesOnceOnSuccessAndFailure() async {
        for tool in ["webview_eval", "webview_dom"] {
            for fails in [false, true] {
                let tracker = CloseTracker()
                let inspector = StubInspector(
                    evalResult: fails ? nil : WebViewEvalResult(jsonValue: "2", webViewIndex: 0),
                    failDom: fails,
                    closeTracker: tracker
                )
                let server = ToolCatalog(executor: DriverToolExecutor(driver: MockDriver(), webInspector: inspector))
                let arguments = tool == "webview_eval" ? ["expression": "1+1"] : ["mode": "html"]
                let result = await server.execute(toolName: tool, arguments: arguments)
                XCTAssertEqual(result.isError, fails, tool)
                let closeCount = await tracker.count
                XCTAssertEqual(closeCount, 1, tool)
            }
        }
    }

    func testWebViewToolsRegistered() {
        let names = ToolCatalog().toolNames()
        XCTAssertTrue(names.contains("webview_eval"))
        XCTAssertTrue(names.contains("webview_dom"))
    }

    func testWebViewEvalReportsNotConfiguredByDefault() async {
        let server = ToolCatalog(executor: DriverToolExecutor(driver: MockDriver()))
        let result = await server.execute(toolName: "webview_eval", arguments: ["expression": "1+1"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("not configured"))
    }

    func testWebViewEvalRequiresExpression() async {
        let server = ToolCatalog(executor: DriverToolExecutor(driver: MockDriver()))
        let result = await server.execute(toolName: "webview_eval", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("expression"))
    }

    func testWebViewEvalMapsResult() async {
        let inspector = StubInspector(evalResult: WebViewEvalResult(
            jsonValue: "\"hidden\"",
            webViewIndex: 0,
            frameURL: "https://youtube.com/embed",
            isException: false
        ))
        let executor = DriverToolExecutor(driver: MockDriver(), webInspector: inspector)
        let server = ToolCatalog(executor: executor)

        let result = await server.execute(
            toolName: "webview_eval",
            arguments: ["expression": "getComputedStyle(x).overflow", "platform": "android"]
        )
        XCTAssertFalse(result.isError)
        guard case let .object(fields)? = result.structuredContent else {
            return XCTFail("expected structured content")
        }
        XCTAssertEqual(fields["value"]?.stringValue, "\"hidden\"")
        XCTAssertEqual(fields["frame_url"]?.stringValue, "https://youtube.com/embed")
        XCTAssertEqual(fields["is_exception"]?.boolValue, false)
    }

    func testWebViewDomMapsDocuments() async {
        let inspector = StubInspector(documents: [
            WebViewDocument(webViewIndex: 0, frameURL: "https://e", content: "<html></html>")
        ])
        let executor = DriverToolExecutor(driver: MockDriver(), webInspector: inspector)
        let server = ToolCatalog(executor: executor)

        let result = await server.execute(toolName: "webview_dom", arguments: ["platform": "android"])
        XCTAssertFalse(result.isError)
        guard case let .object(fields)? = result.structuredContent,
              case let .array(rows)? = fields["documents"],
              case let .object(first)? = rows.first
        else {
            return XCTFail("expected documents array")
        }
        XCTAssertEqual(first["content"]?.stringValue, "<html></html>")
    }
}
