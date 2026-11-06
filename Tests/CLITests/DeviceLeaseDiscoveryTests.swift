import AmooCore
@testable import CLI
import Foundation
import ProcessRunner
import XCTest

final class DeviceLeaseDiscoveryTests: XCTestCase {
    func testMCPLeaseDiscoveryAndCLIListIncludeRuntimeOwnerAndExpiry() async throws {
        let store = try DeviceRuntimeStore(directory: makeScratchDirectory().url)
        let runtime = try store.start(platform: .ios, deviceID: "SIM", owner: "amoo-init")
        let runner = MockCLIProcessRunner(results: [])
        let bootstrapper = DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(processRunner: runner),
            androidCompanionManager: AndroidCompanionManager(processRunner: runner),
            processRunner: runner,
            runtimeStore: store
        )
        let leases = await bootstrapper.deviceLeases()
        XCTAssertEqual(leases["SIM"]?.owner, "amoo-init")
        XCTAssertEqual(leases["SIM"]?.runtimeID, runtime.id)
        XCTAssertEqual(leases["SIM"]?.expiresAt, runtime.expiresAt.ISO8601Format())
        let result = await runEnvList(json: true, store: store)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: [[String: Any]]]
        )
        XCTAssertEqual(object["runtimes"]?.first?["owner"] as? String, "amoo-init")
        XCTAssertNotNil(object["runtimes"]?.first?["expires_at"])
    }
}
