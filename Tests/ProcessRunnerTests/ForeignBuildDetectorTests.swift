import Foundation
import ProcessRunner
import XCTest

private actor StubRunner: ProcessRunner {
    let stdout: String
    let exitCode: Int32
    private(set) var lastCommand: [String]?

    init(stdout: String, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.exitCode = exitCode
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        lastCommand = arguments
        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: "")
    }
}

final class ForeignBuildDetectorTests: XCTestCase {
    func testReportsForeignProcessesAndExcludesOwnAncestry() async {
        let runner = StubRunner(stdout: """
        4242 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing
        777 /usr/bin/xctest -XCTest All /path/OwnHost.xctest
        555 /bin/zsh
        """)
        let detector = ForeignBuildDetector(processRunner: runner, ownProcessIDs: [777])

        let foreign = await detector.foreignBuildProcesses()
        XCTAssertEqual(foreign.count, 1)
        XCTAssertEqual(foreign.first?.hasPrefix("4242 "), true)
        XCTAssertEqual(foreign.first?.contains("xcodebuild"), true)

        let warning = await detector.contentionWarning()
        XCTAssertEqual(warning, ForeignBuildDetector.contentionWarning)

        let command = await runner.lastCommand
        XCTAssertEqual(command, ["pgrep", "-f", "-l", "xcodebuild|xctest"])
    }

    func testNoWarningWhenOnlyOwnProcessesMatch() async {
        let runner = StubRunner(stdout: "777 /usr/bin/xctest -XCTest All /path/OwnHost.xctest\n")
        let detector = ForeignBuildDetector(processRunner: runner, ownProcessIDs: [777])

        let foreign = await detector.foreignBuildProcesses()
        XCTAssertTrue(foreign.isEmpty)
        let warning = await detector.contentionWarning()
        XCTAssertNil(warning)
    }

    /// The companion's own xcodebuild runs for the whole session under a different amoo process.
    func testIgnoresAmooCompanionRuns() async {
        let runner = StubRunner(stdout: """
        26765 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -xctestrun \
        /x/CompanionApps/iOS/build/Build/Products/AmooCompanion_AmooCompanion_iphonesimulator27.0-arm64.xctestrun \
        test-without-building
        """)
        let detector = ForeignBuildDetector(processRunner: runner, ownProcessIDs: [])

        let foreign = await detector.foreignBuildProcesses()
        XCTAssertTrue(foreign.isEmpty)
    }

    func testNoWarningWhenPgrepFindsNothing() async {
        let runner = StubRunner(stdout: "", exitCode: 1)
        let detector = ForeignBuildDetector(processRunner: runner, ownProcessIDs: [])
        let warning = await detector.contentionWarning()
        XCTAssertNil(warning)
    }

    func testDisabledDetectorNeverReports() async {
        let warning = await ForeignBuildDetector.disabled.contentionWarning()
        XCTAssertNil(warning)
    }

    func testAncestryIncludesCurrentProcess() {
        XCTAssertTrue(ProcessAncestry.current().contains(getpid()))
    }
}

final class DeviceHijackParsingTests: XCTestCase {
    func testIOSRunnerTargetingTheDeviceIsAHijackerButTheCompanionIsNot() {
        let ps = """
        9001 /usr/bin/xcodebuild test -destination id=UDID-1 -scheme Other
        9002 /usr/bin/xcodebuild test-without-building -xctestrun AmooCompanion.xctestrun -destination id=UDID-1
        9003 /usr/bin/xcodebuild test -destination id=UDID-2
        777 /usr/bin/xctest id=UDID-1
        """
        let found = ForeignBuildDetector.parseIOSHijackers(ps, udid: "UDID-1", ownProcessIDs: [777])
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].hasPrefix("9001 "))
    }

    func testAndroidInstrumentationThatIsNotTheCompanionIsAHijacker() {
        let ps = """
          PID ARGS
          812 cmd activity instrument -w -r com.example.app.test/androidx.test.runner.AndroidJUnitRunner
          900 cmd activity instrument -w com.amoo.companion.test/com.amoo.companion.CompanionRunner
         1000 /system/bin/logcat
        """
        let found = ForeignBuildDetector.parseAndroidHijackers(ps)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found[0].contains("com.example.app.test"))
    }
}
