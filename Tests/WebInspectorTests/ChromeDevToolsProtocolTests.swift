import Foundation
@testable import WebInspector
import XCTest

final class ChromeDevToolsProtocolTests: XCTestCase {
    func testRequestEncodesIDMethodParams() throws {
        let data = try CDP.encode(CDP.Request(
            id: 7,
            method: "Runtime.evaluate",
            params: ["expression": .string("1+1")]
        ))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["id"] as? Int, 7)
        XCTAssertEqual(json["method"] as? String, "Runtime.evaluate")
        XCTAssertEqual((json["params"] as? [String: Any])?["expression"] as? String, "1+1")
    }

    func testMessageDecodesReplyAndError() throws {
        let reply = try CDP.decode(Data(#"{"id":3,"result":{"result":{"value":42}}}"#.utf8))
        XCTAssertEqual(reply.id, 3)
        XCTAssertEqual(reply.result?["result"]?["value"], .number(42))

        let failure = try CDP.decode(Data(#"{"id":4,"error":{"code":-32000,"message":"nope"}}"#.utf8))
        XCTAssertEqual(failure.error, CDP.CommandError(code: -32000, message: "nope"))
    }

    func testTargetInspectability() throws {
        let targets = try CDP.decodeTargets(Data("""
        [
          {"id":"a","type":"page","url":"https://x","webSocketDebuggerUrl":"ws://127.0.0.1:1/a"},
          {"id":"b","type":"service_worker","webSocketDebuggerUrl":"ws://127.0.0.1:1/b"},
          {"id":"c","type":"page"}
        ]
        """.utf8))
        XCTAssertEqual(targets.filter(\.isInspectablePage).map(\.id), ["a"])
    }

    func testJSONValueJSONString() {
        XCTAssertEqual(JSONValue.number(42).jsonString, "42")
        XCTAssertEqual(JSONValue.number(3.5).jsonString, "3.5")
        XCTAssertEqual(JSONValue.string("hidden").jsonString, "\"hidden\"")
        XCTAssertEqual(JSONValue.bool(true).jsonString, "true")
        XCTAssertEqual(JSONValue.null.jsonString, "null")
        XCTAssertEqual(JSONValue.object(["x": .number(1)]).jsonString, "{\"x\":1}")
    }

    func testFirstDevtoolsSocketParsing() {
        let procNetUnix = """
        Num       RefCount Protocol Flags    Type St Inode Path
        0000: 00000002 00000000 00010000 0001 01 12345 @webview_devtools_remote_4567
        0000: 00000002 00000000 00010000 0001 01 12346 /dev/socket/other
        """
        XCTAssertEqual(
            PlatformWebInspecting.firstDevtoolsSocket(in: procNetUnix),
            "webview_devtools_remote_4567"
        )
        XCTAssertNil(PlatformWebInspecting.firstDevtoolsSocket(in: "nothing here"))
    }
}
