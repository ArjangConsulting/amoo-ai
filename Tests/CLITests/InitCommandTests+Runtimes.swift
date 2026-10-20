import AmooCore
@testable import CLI
import Foundation
import XCTest

extension InitCommandTests {
    func testSetupWithoutAnArtifactPreparesDevicesOnBothPlatforms() async throws {
        let scratch = try makeScratchDirectory()
        for platform in [Platform.ios, .android] {
            let store = DeviceRuntimeStore(directory: scratch.url.appendingPathComponent(platform.rawValue))
            var prepared: [String] = []
            let dependencies = EnvUpDependencies(resolve: { options, _ in
                try EnvDeviceReport(id: XCTUnwrap(options.deviceID), bootedByEnv: false)
            }, start: { _, runtime, store in
                var runtime = runtime
                runtime.port = 22000 + prepared.count
                return try store.refresh(runtime)
            }, prepare: { options, _, app in
                XCTAssertNil(options.appPath)
                XCTAssertNil(options.appID)
                XCTAssertNil(options.appSHA256)
                XCTAssertFalse(options.launch)
                XCTAssertNil(app)
                try prepared.append(XCTUnwrap(options.deviceID))
            })
            let result = await runInitCommand(
                ["--platform", platform.rawValue, "--device", "phone", "--device", "tablet", "--json"],
                runtime: runtime(discovery: discovery(devices: [candidate("phone"), candidate("tablet")])) {
                    await runEnvUp($0, store: store, dependencies: dependencies)
                }
            )
            XCTAssertEqual(result.exitCode, 0, result.output)
            let manifest = try JSONDecoder().decode(InitManifest.self, from: Data(result.output.utf8))
            XCTAssertEqual(prepared, ["phone", "tablet"])
            XCTAssertTrue(manifest.results.allSatisfy { $0.ok && $0.app == nil && $0.runtimeID != nil })
            let cleanup = await runInitDown(manifest, shutdown: false) {
                await runEnvDown($0, store: store, dependencies: EnvDownDependencies(stopAndroid: { _ in true }))
            }
            XCTAssertEqual(cleanup.exitCode, 0, cleanup.output)
            XCTAssertTrue(store.all().isEmpty)
        }
    }
}
