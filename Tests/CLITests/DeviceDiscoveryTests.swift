import AmooCore
@testable import CLI
import XCTest

final class DeviceDiscoveryTests: XCTestCase {
    func testDiscoveryRunsWithoutCompanionAndForwardsFilters() async throws {
        let options = DeviceCommandOptions(
            platform: .ios,
            port: 1,
            deviceID: nil,
            tool: "list_devices",
            arguments: ["platform": "ios", "include_offline": "true"],
            json: true
        )
        let result = await devicePreflight(options) { platform, offline in
            XCTAssertEqual(platform, .ios)
            XCTAssertTrue(offline)
            return [DeviceInfo(id: "fixture", name: "Test phone", platform: .ios, osVersion: "27", state: .shutdown)]
        }
        let output = try XCTUnwrap(result)
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.output.contains("fixture"))
        XCTAssertTrue(output.output.contains("devices"))
    }

    func testInvalidPlatformDoesNotDiscover() async throws {
        let options = DeviceCommandOptions(
            platform: .ios,
            port: 1,
            deviceID: nil,
            tool: "list_devices",
            arguments: ["platform": "invalid"]
        )
        let result = await devicePreflight(options) { _, _ in
            XCTFail("Invalid filters must be rejected before discovery")
            return []
        }
        XCTAssertEqual(try XCTUnwrap(result).exitCode, 1)
    }
}
