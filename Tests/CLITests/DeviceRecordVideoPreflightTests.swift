import AmooCore
import AmooTools
@testable import CLI
import XCTest

/// `record_video` once lived only in the CLI, so the catalog-backed preflight rejected it as an
/// unknown tool before it could run. These go through the same path `amoo device` takes.
final class DeviceRecordVideoPreflightTests: XCTestCase {
    private func prepared(_ args: [String]) async throws -> DeviceCommandPreparation {
        guard case let .success(options) = parseDeviceCommandOptions(args: args) else {
            throw XCTSkip("options did not parse")
        }
        return await prepareDeviceCommand(options)
    }

    func testRecordVideoPassesPreflightOnEveryMobilePlatform() async throws {
        for platform in ["ios", "android"] {
            let preparation = try await prepared([
                "--platform", platform, "record_video", "output=/tmp/amoo-clip.mp4", "duration_seconds=7"
            ])
            guard case let .ready(options) = preparation else {
                if case let .finished(result) = preparation {
                    XCTFail("\(platform): \(result.output)")
                }
                continue
            }
            XCTAssertEqual(options.tool, "record_video")
        }
    }

    func testRecordVideoStillRejectsUnknownArguments() async throws {
        let preparation = try await prepared(["--platform", "ios", "record_video", "output=/tmp/a.mp4", "duration=5"])
        guard case let .finished(result) = preparation else {
            return XCTFail("duration is not an argument of record_video")
        }
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Unknown argument for record_video: duration"), result.output)
    }

    func testRecordVideoRequiresOutput() async throws {
        let preparation = try await prepared(["--platform", "android", "record_video", "duration_seconds=5"])
        guard case let .finished(result) = preparation else {
            return XCTFail("output is required")
        }
        XCTAssertTrue(result.output.contains("Missing required argument: output"), result.output)
    }

    func testCapabilitiesDescribeRecordVideo() {
        let result = runCapabilitiesCommand(["--tool", "record_video"], store: .temporary())
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("duration_seconds"), result.output)
        XCTAssertTrue(result.output.contains("output"), result.output)
    }

    /// Every tool the device help names in an example must reach execution, not stop at preflight.
    func testEveryToolInDeviceHelpExamplesIsInTheCatalog() {
        let catalog = Set(ToolCatalog().cliToolDefinitions().map(\.name))
        // The first bare word after `amoo device` and its `--flag value` pairs is the tool.
        let example = /amoo device(?: --[a-z-]+ \S+)* ([a-z_]+)(?:\s|$)/
        let named = renderDeviceHelp().split(separator: "\n").compactMap { line in
            line.firstMatch(of: example).map { String($0.output.1) }
        }.filter { $0 != "stream" }
        XCTAssertTrue(named.contains("record_video"), "\(named)")
        for tool in named {
            XCTAssertTrue(catalog.contains(tool), "`amoo device \(tool)` is documented but not in the catalog")
        }
    }
}
