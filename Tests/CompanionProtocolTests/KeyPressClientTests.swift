import AmooCore
@testable import CompanionProtocol
import GRPCCore
import Protos
import XCTest

final class KeyPressClientTests: XCTestCase {
    private func client(_ rpc: MockRPCClient) -> GRPCCompanionClient {
        GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
    }

    /// Modifiers go over the wire in a fixed order, so the same chord is always the same request.
    func testSendsKeyNameAndSortedModifiers() async throws {
        let rpc = MockRPCClient()
        try await client(rpc).pressKey(.rightArrow, modifiers: [.shift, .command])
        let request = await rpc.pressKeyRequest
        XCTAssertEqual(request?.key, "right_arrow")
        XCTAssertEqual(request?.modifiers, ["command", "shift"])
    }

    func testCompanionRefusalIsAnError() async {
        let rpc = MockRPCClient()
        await rpc.stubPressKey(success: false)
        do {
            try await client(rpc).pressKey(.character("x"), modifiers: [])
            XCTFail("expected an error")
        } catch let AmooError.commandFailed(command, _) {
            XCTAssertEqual(command, "pressKey x")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStaleCompanionNamesTheFix() async {
        let rpc = MockRPCClient()
        await rpc.stubPressKey(success: true, error: RPCError(code: .unimplemented, message: "no"))
        do {
            try await client(rpc).pressKey(.escape, modifiers: [])
            XCTFail("expected an error")
        } catch let AmooError.unsupportedCapability(key, _) {
            XCTAssertEqual(key, "action.pressKey")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testKeyNamesRoundTrip() {
        for key in KeyboardKey.namedKeys {
            XCTAssertEqual(KeyboardKey(name: key.name), key)
        }
        XCTAssertEqual(KeyboardKey(name: "RETURN"), .returnKey)
        XCTAssertEqual(KeyboardKey(name: "k"), .character("k"))
        XCTAssertNil(KeyboardKey(name: "arrow"))
        XCTAssertNil(KeyboardKey(name: ""))
    }
}

extension MockRPCClient {
    func pressKey(_ request: Amoo_PressKeyRequest) async throws -> Amoo_ActionResponse {
        pressKeyRequest = request
        if let pressKeyError {
            throw pressKeyError
        }
        var response = Amoo_ActionResponse()
        response.success = pressKeySucceeds
        return response
    }

    func stubPressKey(success: Bool, error: (any Error)? = nil) {
        pressKeySucceeds = success
        pressKeyError = error
    }
}
