@testable import CLI
import XCTest

final class MCPCrashLogTests: XCTestCase {
    func testDefaultLogURLHonorsOverride() {
        let url = MCPCrashLog.defaultLogURL(environment: ["AMOO_CRASH_LOG": "/tmp/custom-crash.log"])
        XCTAssertEqual(url.path, "/tmp/custom-crash.log")
    }

    func testDefaultLogURLFallsBackToNamedLogFile() {
        let url = MCPCrashLog.defaultLogURL(environment: [:])
        XCTAssertEqual(url.lastPathComponent, "mcp-serve-crash.log")
    }
}
