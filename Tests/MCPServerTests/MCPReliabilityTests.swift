import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import XCTest

private actor ReliabilityDriver: PlatformDriver {
    var taps = 0
    var scopes: [String?] = []
    var value = ""
    let delay: Swift.Duration

    init(delay: Swift.Duration = .zero) {
        self.delay = delay
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "audit", name: "Audit", platform: .ios, osVersion: "test", state: .booted)
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        try await Task.sleep(for: delay)
        return [ElementInfo(
            id: "target",
            label: "Target",
            value: value,
            frame: Rect(x: 0, y: 0, width: 40, height: 40)
        )]
    }

    func findElements(_ selector: ElementSelector, appID: String?) async throws -> [ElementInfo] {
        scopes.append(appID)
        return try await findElements(selector)
    }

    func setText(_: ElementSelector, text: String, appID: String?) async throws {
        scopes.append(appID)
        value = text
    }

    func getViewHierarchy() async throws -> ViewNode {
        throw AmooError.notImplemented("snapshot failed")
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "app", targetBundleID: "app")
    }

    func tap(at _: Point) async throws {
        taps += 1
    }
}

final class MCPReliabilityTests: XCTestCase {
    func testInvalidResponseStillReturnsErrorWithRequestID() throws {
        let server = MCPStdioServer(server: MCPServer(executor: DriverToolExecutor(driver: ReliabilityDriver())))
        let data = server.encoded(.success(id: .string("request"), result: .double(.nan)))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(response["id"] as? String, "request")
        XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32603)
    }

    func testRequiredHittabilityFailureNeverTaps() async {
        let driver = ReliabilityDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "target", "check_hittable": "true"]
        )
        let taps = await driver.taps
        XCTAssertTrue(result.isError)
        XCTAssertEqual(taps, 0)
    }

    func testAssertionCannotSucceedAfterDeadline() async {
        let driver = ReliabilityDriver(delay: .seconds(3))
        let start = ContinuousClock.now
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_visible", arguments: ["id": "target", "timeout_ms": "30"]
        )
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        XCTAssertTrue(result.isError)
    }

    func testReadBudgetDoesNotWaitForUncooperativeBackend() async {
        let completed = expectation(description: "uncooperative read eventually finishes")
        let start = ContinuousClock.now
        let value: Int? = await DriverToolExecutor.withinBudget(milliseconds: 10) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    continuation.resume(returning: 1)
                    completed.fulfill()
                }
            }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(400))
        XCTAssertNil(value)
        await fulfillment(of: [completed], timeout: 2)
    }

    func testIntegerValidationRejectsDispatcherFallbacks() {
        for raw in ["1e3", "10.0", "nan", "inf", "-1", "3600001"] {
            XCTAssertThrowsError(try ToolRequest(name: "long_press", arguments: ["duration_ms": raw]))
        }
    }

    func testTextEntryPreservesScopeThroughWriteAndVerification() async {
        let driver = ReliabilityDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "set_text", arguments: ["id": "target", "bundle_id": "other.app", "value": "fixture"]
        )
        XCTAssertFalse(result.isError, result.content)
        let scopes = await driver.scopes
        XCTAssertEqual(scopes, ["other.app", "other.app", "other.app"])
    }

    func testCancelledWaiterReturnsBeforeActiveOperationStops() async {
        let queue = DeviceOperationQueue()
        let started = expectation(description: "active operation")
        let active = Task {
            await queue.run(key: "device") {
                started.fulfill()
                try? await Task.sleep(for: .seconds(20))
                return .success("finished")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let waiter = Task { await queue.run(key: "device") { XCTFail("cancelled waiter ran"); return .success("bad") } }
        await Task.yield()
        let start = ContinuousClock.now
        waiter.cancel()
        let result = await waiter.value
        XCTAssertTrue(result.isError)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        active.cancel()
        _ = await active.value
    }

    func testGeometryFormattingRejectsInvalidDeviceNumbers() {
        for number in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(geometryNumber(number), "invalid")
            XCTAssertThrowsError(try validateGeometry([ElementInfo(
                id: "bad",
                label: "Bad",
                frame: Rect(x: number, y: 0, width: 1, height: 1)
            )]))
        }
    }

    func testRecoveryCapacityRemainsAvailableWhenDeviceRequestsAreFull() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let url = try scratch.write(Data(), named: "output")
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let runtime = MCPRequestRuntime(output: output)
        for index in 0 ..< 64 {
            let accepted = await runtime.submit(id: String(index)) {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            XCTAssertTrue(accepted)
        }
        let overloaded = await runtime.submit(id: "full") { nil }
        let recovery = await runtime.submit(id: "recovery", control: true) { nil }
        XCTAssertFalse(overloaded)
        XCTAssertTrue(recovery)
        await runtime.cancelAll()
        try await runtime.drain()
    }
}
