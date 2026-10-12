@testable import CLI
import Foundation
import SwiftyShell
import XCTest

// The ps fixture lines are one record each; wrapping them would stop them looking like ps output.
// swiftlint:disable line_length

final class CompanionOrphanTests: XCTestCase {
    private let udid = "368EE32B-C05D-4A42-83B3-5079A70D2627"

    func testOnlyAnOrphanedRunnerForTheDeviceIsReported() {
        let ps = """
          501     1 /Applications/Xcode.app/usr/bin/xcodebuild -xctestrun /x/AmooCompanion.xctestrun -destination id=\(udid) test-without-building
          502   900 /Applications/Xcode.app/usr/bin/xcodebuild -xctestrun /x/AmooCompanion.xctestrun -destination id=\(udid) test-without-building
          503     1 /Applications/Xcode.app/usr/bin/xcodebuild -xctestrun /x/AmooCompanion.xctestrun -destination id=AAAAAAAA-0000-0000-0000-000000000001 test
          504     1 /Applications/Xcode.app/usr/bin/xcodebuild test -scheme Jot -destination id=\(udid)
          505     1 /usr/bin/python3 AmooCompanion \(udid)
        """
        XCTAssertEqual(
            parseOrphanedCompanionRunners(psOutput: ps, udid: udid.lowercased()),
            [501],
            "live parent, other device, a non-companion build and a non-xcodebuild process are all left alone"
        )
    }

    func testIdleSecondsDefaultToTwoMinutesAndAcceptOverrides() {
        XCTAssertEqual(CompanionManager.idleShutdownSeconds(environment: [:]), 120)
        XCTAssertEqual(CompanionManager.idleShutdownSeconds(environment: ["AMOO_COMPANION_IDLE_SECONDS": "0"]), 0)
        XCTAssertEqual(CompanionManager.idleShutdownSeconds(environment: ["AMOO_COMPANION_IDLE_SECONDS": "30"]), 30)
        XCTAssertEqual(CompanionManager.idleShutdownSeconds(environment: ["AMOO_COMPANION_IDLE_SECONDS": "-1"]), 120)
        XCTAssertEqual(CompanionManager.idleShutdownSeconds(environment: ["AMOO_COMPANION_IDLE_SECONDS": "soon"]), 120)
    }
}

// swiftlint:enable line_length
