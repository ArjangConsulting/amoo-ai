import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import XCTest

final class StartupProgressTests: XCTestCase {
    func testPollableStatusTracksPendingStagesAndFailure() async {
        let operation = StartupOperation(id: "request")
        await StartupProgress.$startup.withValue(operation) {
            await StartupProgress.report("Booting simulator")
            await StartupProgress.report("Building companion")
        }
        let pending = await operation.summary()
        XCTAssertTrue(pending.contains("starting"))
        XCTAssertTrue(pending.contains("Booting simulator"))
        XCTAssertTrue(pending.contains("Building companion"))
        await operation.finish(success: false)
        let failed = await operation.summary()
        XCTAssertTrue(failed.contains("failed"))
    }
}

private struct StartupTestExecutor: ToolExecutor {
    func execute(toolName _: String, arguments _: [String: String]) async -> ToolResult {
        await StartupProgress.report("Booting simulator")
        await StartupProgress.report("Launching companion")
        return .success("ready")
    }
}
