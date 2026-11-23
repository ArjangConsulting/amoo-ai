import AmooCore
@testable import AndroidDriver
import Foundation
import XCTest

/// Copying a file out of an app's storage: external storage with `adb pull`, internal with `run-as`.
final class AndroidAppFileTests: XCTestCase {
    private func makeDriver(_ adb: MockADBRunner) -> AndroidDriver {
        AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5554"
        )
    }

    private func request(_ container: AppStorageContainer, path: String) throws -> AppFileRequest {
        let directory = FileManager.default.temporaryDirectory.appending(path: "android-app-file-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppFileRequest(
            appID: "com.example.app",
            container: container,
            path: path,
            destination: directory.appending(path: "out/session.har")
        )
    }

    func testInternalStorageIsReadThroughRunAsAndDecoded() async throws {
        let adb = MockADBRunner()
        let contents = Data("{\"log\":{\"entries\":[]}}".utf8)
        let body = contents.base64EncodedString(options: .lineLength76Characters)
        await adb.stubRawCommand(
            ["shell", "run-as", "com.example.app", "base64", "'files/my session.har'"],
            outputs: [body + "\n"]
        )
        let request = try request(.data, path: "files/my session.har")

        let file = try await makeDriver(adb).pullAppFile(request)

        XCTAssertEqual(file.devicePath, "/data/data/com.example.app/files/my session.har")
        XCTAssertEqual(file.bytes, contents.count)
        XCTAssertEqual(try Data(contentsOf: request.destination), contents)
        let commands = await adb.rawCommands()
        XCTAssertEqual(
            commands.first,
            ["-s", "emulator-5554", "shell", "run-as", "com.example.app", "test", "-f", "'files/my session.har'"]
        )
    }

    func testARunAsRefusalExplainsTheBuildMustBeDebuggable() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(
            ["shell", "run-as", "com.example.app", "test", "-f", "'files/x.har'"],
            outputs: ["run-as: package not debuggable: com.example.app\n"],
            exitCode: 1
        )

        do {
            _ = try await makeDriver(adb).pullAppFile(request(.data, path: "files/x.har"))
            XCTFail("expected a refusal")
        } catch let AppFileError.unreadable(_, reason) {
            XCTAssertTrue(reason.contains("not a debuggable build"), reason)
            XCTAssertTrue(reason.contains("'external'"), reason)
        }
    }

    func testAMissingExternalFileIsNotFoundAndNeverPulled() async throws {
        let adb = MockADBRunner()
        let devicePath = "/sdcard/Android/data/com.example.app/files/x.har"
        await adb.stubRawCommand(["shell", "test", "-f", "'\(devicePath)'"], outputs: [""], exitCode: 1)

        do {
            _ = try await makeDriver(adb).pullAppFile(request(.external, path: "files/x.har"))
            XCTFail("expected not found")
        } catch let AppFileError.notFound(path) {
            XCTAssertEqual(path, devicePath)
        }
        let pulled = await adb.rawCommands().contains { $0.contains("pull") }
        XCTAssertFalse(pulled)
    }

    func testShellQuotingSurvivesASingleQuote() {
        XCTAssertEqual(AndroidDriver.shellQuoted("files/it's.har"), #"'files/it'\''s.har'"#)
    }
}
