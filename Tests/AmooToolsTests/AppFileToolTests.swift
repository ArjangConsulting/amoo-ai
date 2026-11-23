import AmooCore
@testable import AmooTools
import Foundation
import XCTest

/// `device_pull_app_file`: argument checks, the wait for a file the app writes later, and the result.
final class AppFileToolTests: XCTestCase {
    /// Reports the file missing for the first `missingCalls` calls, then copies `contents`.
    private actor AppFileDriver: PlatformDriver {
        var missingCalls: Int
        var refusal: String?
        private(set) var requests: [AppFileRequest] = []

        init(missingCalls: Int = 0, refusal: String? = nil) {
            self.missingCalls = missingCalls
            self.refusal = refusal
        }

        func pullAppFile(_ request: AppFileRequest) async throws -> PulledAppFile {
            requests.append(request)
            let devicePath = "/data/data/\(request.appID)/\(request.path)"
            if let refusal {
                throw AppFileError.unreadable(devicePath: devicePath, reason: refusal)
            }
            guard missingCalls == 0 else {
                missingCalls -= 1
                throw AppFileError.notFound(devicePath: devicePath)
            }
            return try request.write(Data("{\"log\":{}}".utf8), devicePath: devicePath)
        }
    }

    private func pull(_ driver: AppFileDriver, _ arguments: [String: String]) async -> ToolResult {
        await ToolCatalog(executor: DriverToolExecutor(driver: driver))
            .execute(toolName: "device_pull_app_file", arguments: arguments)
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "app-file-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testCopiesTheFileAndReportsWhereAndHowLarge() async throws {
        let output = try scratch().appending(path: "evidence/session.har")
        let driver = AppFileDriver()

        let result = await pull(driver, [
            "app_id": "com.example.app", "path": "./files//session.har", "output": output.path
        ])

        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["device_path"], .string("/data/data/com.example.app/files/session.har"))
        XCTAssertEqual(fields["output"], .string(output.path))
        XCTAssertEqual(fields["bytes"], .int(10))
        XCTAssertEqual(fields["container"], .string("data"))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "{\"log\":{}}")
        let requests = await driver.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.path, "files/session.har")
    }

    func testWaitsForAFileTheAppWritesLater() async throws {
        let output = try scratch().appending(path: "late.har")
        let driver = AppFileDriver(missingCalls: 2)

        let result = await pull(driver, [
            "app_id": "com.example.app", "path": "files/late.har", "output": output.path, "timeout_ms": "5000"
        ])

        XCTAssertFalse(result.isError, result.content)
        let attempts = await driver.requests.count
        XCTAssertEqual(attempts, 3)
    }

    func testAMissingFileFailsWithItsResolvedPath() async throws {
        let result = try await pull(AppFileDriver(missingCalls: 99), [
            "app_id": "com.example.app", "path": "files/none.har", "output": scratch().path, "timeout_ms": "300"
        ])

        XCTAssertTrue(result.isError)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["code"], .string("file_not_found"))
        XCTAssertEqual(fields["device_path"], .string("/data/data/com.example.app/files/none.har"))
        XCTAssertTrue(result.content.contains("after waiting 300ms"), result.content)
    }

    func testAnUnreadableContainerFailsAtOnceWithTheReason() async throws {
        let driver = AppFileDriver(refusal: "not a debuggable build")

        let result = try await pull(driver, [
            "app_id": "com.example.app", "path": "files/x", "output": scratch().path, "timeout_ms": "5000"
        ])

        XCTAssertEqual(result.structuredContent?.objectValue?["code"], .string("file_unreadable"))
        XCTAssertTrue(result.content.contains("not a debuggable build"), result.content)
        let attempts = await driver.requests.count
        XCTAssertEqual(attempts, 1)
    }

    func testRefusesPathsOutsideTheContainerAndUnknownContainers() async {
        for path in ["/etc/hosts", "files/../../other/x", "", "."] {
            let result = await pull(AppFileDriver(), ["app_id": "com.example.app", "path": path])
            XCTAssertEqual(result.structuredContent?.objectValue?["code"], .string("invalid_argument"), path)
        }
        let container = await pull(AppFileDriver(), [
            "app_id": "com.example.app", "path": "files/x", "container": "sdcard"
        ])
        XCTAssertEqual(container.structuredContent?.objectValue?["code"], .string("invalid_argument"))
        let appID = await pull(AppFileDriver(), ["app_id": "com.example.app; rm", "path": "files/x"])
        XCTAssertEqual(appID.structuredContent?.objectValue?["code"], .string("invalid_argument"))
    }

    func testDefaultsTheOutputToTheFileNameInTheCurrentDirectory() {
        let current = FileManager.default.currentDirectoryPath
        XCTAssertEqual(
            DriverToolExecutor.appFileDestination(output: nil, path: "Documents/net/session.har").path,
            URL(fileURLWithPath: current).appending(path: "session.har").path
        )
        XCTAssertEqual(DriverToolExecutor.appFileDestination(output: "/tmp/a.har", path: "x").path, "/tmp/a.har")
    }
}
