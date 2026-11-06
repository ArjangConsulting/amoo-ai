import AmooCore
@testable import CLI
import Foundation
import TestSession
import XCTest

private actor FreshInstallDriver: PlatformDriver {
    var events: [String] = []
    let installed: Bool
    let failRemoval: Bool

    init(installed: Bool = true, failRemoval: Bool = false) {
        self.installed = installed
        self.failRemoval = failRemoval
    }

    func listApps() async throws -> [AppInfo] {
        installed ? [AppInfo(appID: "app")] : []
    }

    func uninstallApp(appID _: String) async throws {
        events.append("uninstall")
        if failRemoval {
            throw SessionBootstrapError.unsupported
        }
    }

    func installApp(path _: String) async throws {
        events.append("install")
    }

    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {
        events.append("launch")
    }

    func setTargetApp(bundleID _: String?) async throws {}
}

final class FreshInstallTests: XCTestCase {
    private func bootstrapper() -> DefaultSessionBootstrapper {
        DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(),
            androidCompanionManager: AndroidCompanionManager(),
            runtimeStore: .temporary()
        )
    }

    func testFreshInstallRemovesBeforeInstallOnBothPlatforms() async throws {
        for platform: Platform in [.ios, .android] {
            let driver = FreshInstallDriver()
            _ = try await bootstrapper().installAndLaunch(
                SessionBootstrapRequest(appID: "app", platform: platform, buildPath: "/fixture", freshInstall: true),
                driver: driver
            )
            let events = await driver.events
            XCTAssertEqual(events, ["uninstall", "install", "launch"])
        }
    }

    func testReinstallPreservesDataByDefaultAndFreshInstallHandlesMissingApp() async throws {
        for (installed, fresh) in [(true, false), (false, true)] {
            let driver = FreshInstallDriver(installed: installed)
            _ = try await bootstrapper().installAndLaunch(
                SessionBootstrapRequest(appID: "app", platform: .ios, buildPath: "/fixture", freshInstall: fresh),
                driver: driver
            )
            let events = await driver.events
            XCTAssertEqual(events, ["install", "launch"])
        }
    }

    func testUninstallFailureStopsInstallationAndLaunch() async {
        let driver = FreshInstallDriver(failRemoval: true)
        do {
            _ = try await bootstrapper().installAndLaunch(
                SessionBootstrapRequest(appID: "app", platform: .android, buildPath: "/fixture", freshInstall: true),
                driver: driver
            )
            XCTFail("Uninstall failure must stop startup")
        } catch {
            let events = await driver.events
            XCTAssertEqual(events, ["uninstall"])
        }
    }
}
