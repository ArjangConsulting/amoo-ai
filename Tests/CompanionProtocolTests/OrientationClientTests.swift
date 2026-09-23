import AmooCore
@testable import CompanionProtocol
import GRPCCore
import Protos
import XCTest

final class OrientationClientTests: XCTestCase {
    private func client(_ rpc: MockRPCClient) -> GRPCCompanionClient {
        GRPCCompanionClient(connection: .init(host: "localhost", port: 22087), rpcClient: rpc)
    }

    func testEveryOrientationRoundTripsThroughTheWireFormat() async throws {
        let rpc = MockRPCClient()
        for orientation in DeviceOrientation.allCases {
            let reported = try await client(rpc).setOrientation(orientation)
            XCTAssertEqual(reported, orientation)
        }
    }

    /// The device's answer is what comes back, so a rotation it refused is visible.
    func testReportsWhatTheDeviceSaysNotWhatWasAsked() async throws {
        let rpc = MockRPCClient()
        await rpc.stubOrientation(reported: .portrait)
        let reported = try await client(rpc).setOrientation(.landscapeLeft)
        XCTAssertEqual(reported, .portrait)
    }

    func testUnspecifiedAnswerIsAnError() async {
        let rpc = MockRPCClient()
        await rpc.stubOrientation(reported: .unspecified)
        do {
            _ = try await client(rpc).setOrientation(.portrait)
            XCTFail("expected an error")
        } catch let AmooError.commandFailed(command, _) {
            XCTAssertEqual(command, "setOrientation")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// A companion started before the RPC existed answers UNIMPLEMENTED until it is restarted.
    func testStaleCompanionNamesTheFix() async {
        let rpc = MockRPCClient()
        await rpc.stubOrientation(reported: nil, error: RPCError(code: .unimplemented, message: "no"))
        do {
            _ = try await client(rpc).setOrientation(.portrait)
            XCTFail("expected an error")
        } catch let AmooError.unsupportedCapability(key, reason) {
            XCTAssertEqual(key, "action.setOrientation")
            XCTAssertTrue(reason.contains("amoo companion start"), reason)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

extension MockRPCClient {
    func setOrientation(_ request: Amoo_SetOrientationRequest) async throws -> Amoo_OrientationResponse {
        if let orientationError {
            throw orientationError
        }
        var response = Amoo_OrientationResponse()
        response.orientation = reportedOrientation ?? request.orientation
        return response
    }

    func stubOrientation(reported: Amoo_Orientation?, error: (any Error)? = nil) {
        reportedOrientation = reported
        orientationError = error
    }
}
