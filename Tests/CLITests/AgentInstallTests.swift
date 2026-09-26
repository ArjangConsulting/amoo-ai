@testable import CLI
import Foundation
import XCTest

final class AgentInstallTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testBundledAgentFilesAreFoundFromACheckout() {
        let root = agentAssetsRoot(executableURL: nil, currentDirectoryPath: repoRoot.path)
        XCTAssertEqual(root?.standardizedFileURL, repoRoot.standardizedFileURL)
    }

    func testInstallsOnceAndNeverClobbersLocalEditsWithoutForce() throws {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: target) }
        let options = AgentInstallOptions(target: target.path)

        XCTAssertEqual(runAgentInstall(options, assetsRoot: repoRoot).exitCode, 0)
        let agent = target.appendingPathComponent(".claude/agents/device-verifier.md")
        XCTAssertTrue(try String(contentsOf: agent, encoding: .utf8).contains("name: device-verifier"))

        try "local edit".write(to: agent, atomically: true, encoding: .utf8)
        XCTAssertTrue(runAgentInstall(options, assetsRoot: repoRoot).output.contains("skipped"))
        XCTAssertEqual(try String(contentsOf: agent, encoding: .utf8), "local edit")

        var forced = options
        forced.force = true
        XCTAssertTrue(runAgentInstall(forced, assetsRoot: repoRoot).output.contains("updated"))
    }

    func testMissingAssetsFailClearly() {
        let result = runAgentInstall(AgentInstallOptions(target: "/tmp"), assetsRoot: nil)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Cannot find the bundled agent files"))
    }
}
