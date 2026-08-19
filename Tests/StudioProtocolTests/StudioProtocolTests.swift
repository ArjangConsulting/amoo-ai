import Foundation
import StudioProtocol
import Testing

@Suite("Studio protocol")
struct StudioProtocolTests {
    @Test("handshake reports the protocol version and capabilities")
    func handshake() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake","params":{}}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])

        #expect(result["protocolVersion"] as? Int == StudioService.protocolVersion)
        #expect(result["product"] as? String == "amoo")
        #expect(result["capabilities"] as? [String] == ["health"])
    }

    @Test("unknown methods return JSON-RPC method-not-found")
    func methodNotFound() async throws {
        let request = Data(#"{"jsonrpc":"2.0","id":"abc","method":"missing"}"#.utf8)
        let response = await StudioService().handle(request)
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(error["code"] as? Int == -32601)
    }
}
