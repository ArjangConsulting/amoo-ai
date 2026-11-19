// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import XCTest

/// Launch arguments (a locale, a feature flag) used to be delivered silently, so an agent could
/// only infer from the screen that `-AppleLanguages (fa)` had arrived.
final class AppLaunchReceiptTests: XCTestCase {
    func testReportsArgumentDeliveryAndCountButNeverValues() throws {
        let receipt = AppLaunchReceipt(
            appID: "com.example", freshProcess: true, environmentDelivery: "not_requested", environmentKeys: [],
            argumentsDelivery: "process_arguments", argumentCount: 4
        )
        let json = try XCTUnwrap(String(bytes: JSONEncoder().encode(receipt), encoding: .utf8))
        XCTAssertTrue(json.contains("\"arguments_delivery\":\"process_arguments\""), json)
        XCTAssertTrue(json.contains("\"argument_count\":4"), json)
    }

    func testRoundTrips() throws {
        let receipt = AppLaunchReceipt(
            appID: "com.example", freshProcess: nil, environmentDelivery: "intent_extras", environmentKeys: ["B", "A"],
            argumentsDelivery: "intent_extras", argumentCount: 2
        )
        let decoded = try JSONDecoder().decode(AppLaunchReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(decoded, receipt)
    }

    func testReceiptWrittenBeforeArgumentDeliveryDecodesAsUnknown() throws {
        let json = #"{"app_id":"com.example","fresh_process":true,"#
            + #""environment_delivery":"process_environment","environment_keys":["A"]}"#
        let legacy = Data(json.utf8)
        let decoded = try JSONDecoder().decode(AppLaunchReceipt.self, from: legacy)
        XCTAssertEqual(decoded.argumentsDelivery, "unknown")
        XCTAssertEqual(decoded.argumentCount, 0)
    }

    func testDefaultReceiptCannotClaimDelivery() async throws {
        let receipt = try await LaunchOnlyApps().launchAppWithReceipt(
            appID: "com.example", arguments: ["-flag"], environment: [:]
        )
        XCTAssertEqual(receipt.argumentsDelivery, "unknown")
        XCTAssertEqual(receipt.argumentCount, 1)
    }
}

private struct LaunchOnlyApps: AppManagement {
    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID _: String) async throws {}
    func uninstallApp(appID _: String) async throws {}
    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .unknown
    }
}

// swiftlint:enable multiline_arguments
