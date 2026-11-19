@testable import CLI
import XCTest

/// The Android runtime check took a forwarded port and a capabilities answer as proof of life,
/// but the companion's app process can outlive the `am instrument` session that drives the UI.
final class AndroidInstrumentationProbeTests: XCTestCase {
    private static let running = "ARGS\n"
        + "app_process /system/bin com.android.commands.am.Am instrument -w"
        + " -e class com.amoo.companion.CompanionRunner -e port 22096"
        + " com.amoo.companion.test/androidx.test.runner.AndroidJUnitRunner\n"
        + "com.amoo.companion\n"

    func testInstrumentationForThePortIsRunning() {
        XCTAssertTrue(androidInstrumentationRunning(psOutput: Self.running, port: 22096))
    }

    func testAppProcessWithoutInstrumentationIsNotRunning() {
        XCTAssertFalse(androidInstrumentationRunning(psOutput: "ARGS\ncom.amoo.companion\n", port: 22096))
    }

    func testInstrumentationForAnotherPortDoesNotCount() {
        XCTAssertFalse(androidInstrumentationRunning(psOutput: Self.running, port: 22093))
    }
}
