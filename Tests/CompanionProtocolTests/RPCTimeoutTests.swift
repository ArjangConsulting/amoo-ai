@testable import CompanionProtocol
import XCTest

final class RPCTimeoutTests: XCTestCase {
    func testDefaultsToTwelveSeconds() {
        XCTAssertEqual(LiveCompanionRPCClient.gestureTimeout(environment: [:]), .seconds(12))
    }

    func testHonorsTheEnvironmentOverride() {
        let environment = [LiveCompanionRPCClient.timeoutEnvironmentKey: "45"]
        XCTAssertEqual(LiveCompanionRPCClient.gestureTimeout(environment: environment), .seconds(45))
    }

    func testIgnoresValuesOutsideOneToSixHundred() {
        for raw in ["0", "-3", "601", "soon", ""] {
            let environment = [LiveCompanionRPCClient.timeoutEnvironmentKey: raw]
            XCTAssertEqual(LiveCompanionRPCClient.gestureTimeout(environment: environment), .seconds(12), raw)
        }
    }
}
