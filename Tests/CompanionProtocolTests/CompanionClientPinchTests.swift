import AmooCore
@testable import CompanionProtocol
import XCTest

final class CompanionClientPinchTests: XCTestCase {
    func testPinchSendsCenterScaleAndVelocity() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.pinch(
            center: Point(x: 150, y: 300),
            scale: 2.5,
            velocity: 1.5,
            bounds: Rect(x: 10, y: 200, width: 280, height: 200)
        )

        let req = await rpcClient.pinchRequest
        XCTAssertEqual(req?.center.x, 150)
        XCTAssertEqual(req?.center.y, 300)
        XCTAssertEqual(req?.scale, 2.5)
        XCTAssertEqual(req?.velocity, 1.5)
        XCTAssertEqual(req?.bounds.y, 200)
        XCTAssertEqual(req?.bounds.width, 280)
        let calls = await rpcClient.actionCalls
        XCTAssertEqual(calls, ["pinch"])
    }
}
