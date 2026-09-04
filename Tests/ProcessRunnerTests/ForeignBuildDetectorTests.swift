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
