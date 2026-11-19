import AmooCore
@testable import CompanionProtocol
import GRPCCore
import Protos
import XCTest

final class HitTestClientTests: XCTestCase {
    private static let fab = ElementInfo(
        id: "options_button", label: "Playback options", frame: Rect(x: 16, y: 760, width: 56, height: 56)
    )

    private func client(_ rpc: MockRPCClient) -> GRPCCompanionClient {
        GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
    }

    func testSendsTheElementsIdentityAndFrame() async throws {
        let rpc = MockRPCClient()
        let verdict = try await client(rpc).hitTest(Self.fab, appID: "com.novalingo", candidateBundleIDs: ["a"])
        XCTAssertEqual(verdict, .hittable)
        let sent = await rpc.hitTestRequest
        let request = try XCTUnwrap(sent)
        XCTAssertEqual(request.id, "options_button")
        XCTAssertEqual(request.label, "Playback options")
        XCTAssertEqual(request.frame.y, 760)
        XCTAssertEqual(request.frame.width, 56)
        XCTAssertEqual(request.appID, "com.novalingo")
        XCTAssertEqual(request.candidateBundleIds, ["a"])
    }

    func testMapsEveryVerdict() async throws {
        let cases: [(Amoo_HitTestVerdict, HitTestVerdict)] = [
            (.hittable, .hittable), (.notHittable, .notHittable), (.unresolved, .unresolved), (
                .unspecified,
                .unsupported
            )
        ]
        for (wire, expected) in cases {
            let rpc = MockRPCClient()
            await rpc.stubHitTest(.success(wire))
            let verdict = try await client(rpc).hitTest(Self.fab, appID: nil, candidateBundleIDs: [])
            XCTAssertEqual(verdict, expected, "\(wire)")
        }
    }

    /// A companion started before the RPC existed answers UNIMPLEMENTED; the host then keeps its
    /// own judgement instead of failing the tap.
    func testStaleCompanionIsUnsupportedRatherThanAnError() async throws {
        let rpc = MockRPCClient()
        await rpc.stubHitTest(.failure(RPCError(code: .unimplemented, message: "no")))
        let verdict = try await client(rpc).hitTest(Self.fab, appID: nil, candidateBundleIDs: [])
        XCTAssertEqual(verdict, .unsupported)
    }

    func testOtherTransportErrorsStillThrow() async {
        let rpc = MockRPCClient()
        await rpc.stubHitTest(.failure(RPCError(code: .deadlineExceeded, message: "slow")))
        do {
            _ = try await client(rpc).hitTest(Self.fab, appID: nil, candidateBundleIDs: [])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? RPCError)?.code, .deadlineExceeded)
        }
    }
}

extension MockRPCClient {
    func hitTest(_ request: Amoo_HitTestRequest) async throws -> Amoo_HitTestResponse {
        hitTestRequest = request
        var response = Amoo_HitTestResponse()
        response.verdict = try hitTestAnswer.get()
        return response
    }

    func stubHitTest(_ answer: Result<Amoo_HitTestVerdict, any Error>) {
        hitTestAnswer = answer
    }
}
