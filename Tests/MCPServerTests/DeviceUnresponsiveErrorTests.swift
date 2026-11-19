import MobileCore
@testable import ProcessRunner
import XCTest

/// A launch whose `adb … am force-stop` timed out read like a launch failure. The device had stopped
/// answering, and the message now says so and names the recovery.
final class DeviceUnresponsiveErrorTests: XCTestCase {
    func testATimedOutDeviceCommandReportsAnUnresponsiveDevice() async {
        do {
            _ = try await translatingMobileKitErrors { () async throws -> Int in
                throw MobileKitError.timedOut(
                    operation: "adb -s emulator-5554 shell am force-stop com.example",
                    seconds: 30
                )
            }
            XCTFail("expected an error")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(
                error,
                .deviceUnresponsive(operation: "adb -s emulator-5554 shell am force-stop com.example", seconds: 30)
            )
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("did not respond"), message)
            XCTAssertTrue(message.contains("env up"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
