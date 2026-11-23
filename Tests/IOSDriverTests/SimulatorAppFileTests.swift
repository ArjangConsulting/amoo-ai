import AmooCore
import Foundation
@testable import IOSDriver
import ProcessRunner
import XCTest

/// A simulator's app data container is on the host, so a file is copied straight out of it.
final class SimulatorAppFileTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sim-app-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func request(_ path: String, into directory: URL, container: AppStorageContainer = .data) throws
        -> AppFileRequest {
        try AppFileRequest(
            appID: "com.example.app",
            container: container,
            path: path,
            destination: directory.appending(path: "pulled/session.har")
        )
    }

    func testCopiesFromTheDataContainerAndReplacesAnOlderCopy() async throws {
        let root = try scratch()
        let container = root.appending(path: "container")
        try FileManager.default.createDirectory(
            at: container.appending(path: "Documents"),
            withIntermediateDirectories: true
        )
        try Data("{\"log\":{}}".utf8).write(to: container.appending(path: "Documents/session.har"))
        let simctl = MockSimctlRunner()
        await simctl.setDataContainer(container.path)
        let backend = SimulatorHostBackend(simctl: simctl)
        let request = try request("Documents/session.har", into: root)
        try FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: request.destination)

        let file = try await backend.pullAppFile(device: "SIM-1", request: request)

        XCTAssertEqual(file.bytes, 10)
        XCTAssertEqual(file.devicePath, container.appending(path: "Documents/session.har").path)
        XCTAssertEqual(try String(contentsOf: request.destination, encoding: .utf8), "{\"log\":{}}")
    }

    func testAMissingFileIsNotFoundAndAMissingAppIsUnreadable() async throws {
        let root = try scratch()
        let simctl = MockSimctlRunner()
        await simctl.setDataContainer(root.path)
        let backend = SimulatorHostBackend(simctl: simctl)

        do {
            _ = try await backend.pullAppFile(device: "SIM-1", request: request("Documents/none.har", into: root))
            XCTFail("expected not found")
        } catch let AppFileError.notFound(path) {
            XCTAssertEqual(path, root.appending(path: "Documents/none.har").path)
        }

        await simctl.setDataContainer(nil)
        do {
            _ = try await backend.pullAppFile(device: "SIM-1", request: request("Documents/none.har", into: root))
            XCTFail("expected unreadable")
        } catch let AppFileError.unreadable(_, reason) {
            XCTAssertTrue(reason.contains("is it installed"), reason)
        }
    }

    func testExternalStorageIsAndroidOnly() async throws {
        let backend = SimulatorHostBackend(simctl: MockSimctlRunner())
        do {
            _ = try await backend.pullAppFile(
                device: "SIM-1",
                request: request("files/x", into: scratch(), container: .external)
            )
            XCTFail("expected unsupported")
        } catch let AmooError.unsupportedCapability(key, _) {
            XCTAssertEqual(key, "app.files.external")
        }
    }

    func testADeviceCopyFailureNamesTheBuildTypeLimit() {
        let missing = PhysicalDeviceHostBackend.appFileError(
            output: "The file doesn’t exist.",
            devicePath: "com.example.app data:Documents/x"
        )
        XCTAssertEqual(missing, .notFound(devicePath: "com.example.app data:Documents/x"))
        guard case let .unreadable(_, reason) = PhysicalDeviceHostBackend.appFileError(
            output: "Failed to acquire container",
            devicePath: "com.example.app data:Documents/x"
        ) else {
            return XCTFail("expected unreadable")
        }
        XCTAssertTrue(reason.contains("development-signed"), reason)
    }
}
