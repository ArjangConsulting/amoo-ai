import Foundation
@testable import MCPServer
import WebInspector
import XCTest

private struct StubInspector: WebInspecting {
    var evalResult: WebViewEvalResult?
    var documents: [WebViewDocument] = []

    func client(platform _: WebInspectorPlatform, bundleID: String?) async throws -> any WebInspectorClient {
        StubClient(evalResult: evalResult, documents: documents, bundleID: bundleID)
    }
}

private struct StubClient: WebInspectorClient {
    var evalResult: WebViewEvalResult?
    var documents: [WebViewDocument]
    var bundleID: String?

    func evaluate(_: WebViewEvalRequest) async throws -> WebViewEvalResult {
        guard let evalResult else { throw WebInspectorError.noInspectableWebViews(bundleID: bundleID) }
        return evalResult
    }

    func dom(_: WebViewDomRequest) async throws -> [WebViewDocument] {
        documents
    }
}

final class WebViewToolsTests: XCTestCase {
    func testWebViewToolsRegistered() {
        let names = MCPServer().toolNames()
        XCTAssertTrue(names.contains("webview_eval"))
        XCTAssertTrue(names.contains("webview_dom"))
    }

    func testWebViewEvalReportsNotConfiguredByDefault() async {
        let server = MCPServer(executor: DriverToolExecutor(driver: MockDriver()))
        let result = await server.execute(toolName: "webview_eval", arguments: ["expression": "1+1"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("not configured"))
    }

    func testWebViewEvalRequiresExpression() async {
        let server = MCPServer(executor: DriverToolExecutor(driver: MockDriver()))
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
        let server = MCPServer(executor: executor)

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
        let server = MCPServer(executor: executor)

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
