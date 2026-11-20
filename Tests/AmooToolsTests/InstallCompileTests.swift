import AmooCore
@testable import AmooTools
import TestCommons
import XCTest

/// An APK installed by amoo ran from its APK, so every first cold start inflated its dex on the
/// main thread and a loaded emulator killed it. `compile=verify` compiles right after install.
final class InstallCompileTests: XCTestCase {
    private func apk() throws -> (TemporaryDirectory, String) {
        let scratch = try TemporaryDirectory()
        let url = try scratch.write(Data("apk".utf8), named: "app.apk")
        return (scratch, url.path)
    }

    func testCompileRunsAfterTheInstallAndIsReported() async throws {
        let (scratch, path) = try apk()
        defer { try? scratch.remove() }
        let driver = CompilingDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "device_install_app", arguments: ["path": path, "compile": "verify", "app_id": "com.example"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["compile"]?.objectValue?["mode"], .string("verify"))
        let events = await driver.events
        XCTAssertEqual(events, ["install", "compile verify com.example"])
    }

    func testCompileWithoutAnAppIDFailsBeforeInstalling() async throws {
        let (scratch, path) = try apk()
        defer { try? scratch.remove() }
        let driver = CompilingDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "device_install_app", arguments: ["path": path, "compile": "verify"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("app_id"), result.content)
        let events = await driver.events
        XCTAssertTrue(events.isEmpty, "nothing installed")
    }

    func testAPlatformWithoutCompilationRefusesBeforeInstalling() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let bundle = scratch.url.appending(path: "App.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let driver = MockDriver()
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "device_install_app",
            arguments: ["path": bundle.path, "compile": "verify", "app_id": "com.example"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Android-only"), result.content)
    }
}

private actor CompilingDriver: PlatformDriver, AppCompiling {
    private(set) var events: [String] = []

    func installApp(path _: String) async throws {
        events.append("install")
    }

    func compileApp(appID: String, mode: String) async throws -> String {
        events.append("compile \(mode) \(appID)")
        return "Success"
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        []
    }

    func getViewHierarchy(appID _: String?) async throws -> ViewNode {
        ViewNode(id: "root")
    }
}
