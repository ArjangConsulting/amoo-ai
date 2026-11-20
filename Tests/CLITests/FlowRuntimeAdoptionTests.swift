@testable import CLI
import Foundation
import XCTest

/// `amoo flow --runtime-id` took the runtime's lease but kept simctl's `booted` and the default
/// port, so with four simulators booted a reset flow uninstalled and reinstalled the app on another
/// session's simulator. The runtime now names the device and port.
final class FlowRuntimeAdoptionTests: XCTestCase {
    private func store(port: Int? = 22094) throws -> (DeviceRuntimeStore, DeviceRuntime) {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: .ios, deviceID: "D5687BD6", owner: "bench")
        runtime.port = port
        runtime = try store.refresh(runtime)
        return (store, runtime)
    }

    private func flow(device: String? = nil, port: Int? = nil, platform: String = "ios") -> TestFlow {
        TestFlow(platform: platform, port: port, deviceID: device, steps: [])
    }

    func testRuntimeSuppliesDeviceAndPort() throws {
        let (store, runtime) = try store()
        var flow = flow()
        try adoptPresentedRuntime(
            &flow,
            overrides: FlowOverrides(runtimeID: runtime.id),
            store: store,
            environment: [:]
        )
        XCTAssertEqual(flow.deviceID, "D5687BD6")
        XCTAssertEqual(flow.port, 22094)
    }

    func testRuntimeReplacesWhatTheFileBakedIn() throws {
        let (store, runtime) = try store()
        var flow = flow(device: "58772957", port: 22087)
        try adoptPresentedRuntime(
            &flow,
            overrides: FlowOverrides(runtimeID: runtime.id),
            store: store,
            environment: [:]
        )
        XCTAssertEqual(flow.deviceID, "D5687BD6")
        XCTAssertEqual(flow.port, 22094)
    }

    func testExplicitPortWins() throws {
        let (store, runtime) = try store()
        var flow = flow(port: 22111)
        try adoptPresentedRuntime(
            &flow, overrides: FlowOverrides(port: 22111, runtimeID: runtime.id), store: store, environment: [:]
        )
        XCTAssertEqual(flow.deviceID, "D5687BD6")
        XCTAssertEqual(flow.port, 22111)
    }

    /// `--devices` sets each device explicitly; the runtime's port belongs to its own device only.
    func testExplicitOtherDeviceKeepsItsOwnPort() throws {
        let (store, runtime) = try store()
        var flow = flow(device: "C342D46C")
        try adoptPresentedRuntime(
            &flow, overrides: FlowOverrides(deviceID: "C342D46C", runtimeID: runtime.id), store: store, environment: [:]
        )
        XCTAssertEqual(flow.deviceID, "C342D46C")
        XCTAssertNil(flow.port)
    }

    func testAmbientRuntimeIsAdopted() throws {
        let (store, runtime) = try store()
        var flow = flow()
        try adoptPresentedRuntime(
            &flow,
            overrides: FlowOverrides(),
            store: store,
            environment: ["AMOO_RUNTIME_ID": runtime.id]
        )
        XCTAssertEqual(flow.deviceID, "D5687BD6")
    }

    func testNoRuntimeLeavesTheFlowAlone() throws {
        let (store, _) = try store()
        var flow = flow(device: "58772957", port: 22087)
        try adoptPresentedRuntime(&flow, overrides: FlowOverrides(), store: store, environment: [:])
        XCTAssertEqual(flow.deviceID, "58772957")
        XCTAssertEqual(flow.port, 22087)
    }

    func testUnknownRuntimeFlagIsAnError() throws {
        let (store, _) = try store()
        var flow = flow()
        XCTAssertThrowsError(
            try adoptPresentedRuntime(
                &flow,
                overrides: FlowOverrides(runtimeID: "runtime-gone"),
                store: store,
                environment: [:]
            )
        ) { error in
            XCTAssertEqual(error as? DeviceAccessError, .unknownRuntime("runtime-gone"))
        }
    }

    func testPlatformMismatchIsAnError() throws {
        let (store, runtime) = try store()
        var flow = flow(platform: "android")
        XCTAssertThrowsError(
            try adoptPresentedRuntime(
                &flow,
                overrides: FlowOverrides(runtimeID: runtime.id),
                store: store,
                environment: [:]
            )
        )
    }

    func testDevicelessFlowFollowsTheCompanionsSimulator() async throws {
        var flow = flow(port: 22094)
        let port = try await flowCompanionPort(&flow, platform: .ios, overrides: .init()) { port in
            port == 22094 ? "D5687BD6" : nil
        }
        XCTAssertEqual(port, 22094)
        XCTAssertEqual(flow.deviceID, "D5687BD6")
    }

    func testFlowRefusesACompanionForAnotherSimulator() async throws {
        let requested = "D5687BD6-6B26-49AE-AF56-A423984999AB"
        let owner = "C342D46C-EF2D-4439-BCA0-3E0D5AB94785"
        var flow = flow(device: requested, port: 22094)
        do {
            _ = try await flowCompanionPort(&flow, platform: .ios, overrides: .init()) { _ in owner }
            XCTFail("Expected a companion mismatch")
        } catch {
            XCTAssertTrue(String(describing: error).contains(owner), "\(error)")
        }
    }
}
