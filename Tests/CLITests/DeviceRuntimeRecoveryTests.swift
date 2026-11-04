import AmooCore
@testable import CLI
import Foundation
import XCTest

final class DeviceRuntimeRecoveryTests: XCTestCase {
    func testRecoveryAndReinstallRetainRuntimeIdentityAndEndpoint() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: .ios, deviceID: "SIM", owner: "verifier")
        runtime.port = 22093
        runtime.companionPID = 123
        runtime.state = .unresponsive
        runtime = try store.refresh(runtime)
        var dependencies = EnvUpDependencies()
        dependencies.health = DeviceRuntimeHealth(processMatches: { _, _ in true }, isReady: { _ in false })
        var stoppedIDs: [String] = []
        var preparedIDs: [String] = []
        dependencies.stop = { stoppedIDs.append($0.id); return true }
        dependencies.start = { _, owned, store in
            var recovered = owned
            recovered.companionPID = 456
            recovered.state = .running
            return try store.refresh(recovered)
        }
        dependencies.prepare = { options, owned, app in
            preparedIDs.append(owned.id)
            XCTAssertEqual(options.appPath, "/fixture/App.app")
            app?.installed = true
        }
        let options = EnvUpOptions(
            runtimeID: runtime.id, platform: .ios, appPath: "/fixture/App.app", appID: "com.example.app", json: true
        )
        let result = await runEnvUp(options, store: store, dependencies: dependencies)
        XCTAssertEqual(result.exitCode, 0, result.output)
        let report = try JSONDecoder().decode(EnvUpReport.self, from: Data(result.output.utf8))
        XCTAssertEqual(report.runtimeID, runtime.id)
        XCTAssertEqual(report.port, 22093)
        XCTAssertEqual(report.recovered, true)
        XCTAssertEqual(report.app?.installed, true)
        XCTAssertNotNil(report.recoveryMilliseconds)
        XCTAssertEqual(stoppedIDs, [runtime.id])
        XCTAssertEqual(preparedIDs, [runtime.id])
        XCTAssertEqual(store.all().map(\.id), [runtime.id])
        dependencies.health = DeviceRuntimeHealth(processMatches: { _, _ in true }, isReady: { _ in true })
        let reinstalled = await runEnvUp(options, store: store, dependencies: dependencies)
        XCTAssertEqual(reinstalled.exitCode, 0, reinstalled.output)
        XCTAssertEqual(stoppedIDs.count, 1)
        XCTAssertEqual(preparedIDs, [runtime.id, runtime.id])
    }

    func testRecoveryCannotBypassActiveDeviceLockAndFailedStopKeepsOwnership() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        var runtime = try store.start(platform: .ios, deviceID: "SIM")
        runtime.state = .stale
        runtime = try store.refresh(runtime)
        var dependencies = EnvUpDependencies()
        dependencies.health = DeviceRuntimeHealth(processMatches: { _, _ in false }, isReady: { _ in false })
        var stopCalls = 0
        dependencies.stop = { _ in stopCalls += 1; return false }
        let access = try DeviceAccessLock(deviceID: "SIM", store: store)
        let options = EnvUpOptions(runtimeID: runtime.id, platform: .ios, json: true)
        let locked = await runEnvUp(options, store: store, dependencies: dependencies)
        XCTAssertNotEqual(locked.exitCode, 0)
        XCTAssertEqual(stopCalls, 0)
        access.release()
        let refused = await runEnvUp(options, store: store, dependencies: dependencies)
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertEqual(stopCalls, 1)
        XCTAssertEqual(store.allIncludingExpired().map(\.id), [runtime.id])
    }
}
