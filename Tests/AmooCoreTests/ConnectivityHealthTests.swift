import AmooCore
import XCTest

final class ConnectivityHealthTests: XCTestCase {
    func testUnresponsiveAndroidExecutionIsNotHealthyEvenWhenBothChannelsRespond() {
        let responded = ConnectivityHealth.Probe(status: "responded", source: "fixture")
        let health = ConnectivityHealth(
            deviceTransport: responded,
            companionRPC: responded,
            deviceExecution: .init(status: "timed_out", source: "Android shell echo")
        )
        XCTAssertEqual(health.failureScope, "device_execution")
    }

    func testCompanionFailureIsSeparateFromADeviceTransportFailure() {
        var health = ConnectivityHealth(
            deviceTransport: .init(status: "responded", source: "adb"),
            companionRPC: .init(status: "timed_out", source: "rpc")
        )
        XCTAssertEqual(health.failureScope, "companion_channel")
        health.deviceTransport.status = "failed"
        XCTAssertEqual(health.failureScope, "device_transport")
        health.deviceTransport.status = "unavailable"
        XCTAssertEqual(health.failureScope, "unknown")
    }

    func testRespondingChannelsDoNotClaimAppReadiness() async {
        let probe = await ConnectivityHealth.probe(source: "fixture") {}
        XCTAssertEqual(probe.status, "responded")
        let health = ConnectivityHealth(deviceTransport: probe, companionRPC: probe)
        XCTAssertEqual(health.failureScope, "none")
    }
}
