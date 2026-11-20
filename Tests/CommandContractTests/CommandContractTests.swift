import AmooTools
import CommandContract
import XCTest

final class CommandContractTests: XCTestCase {
    func testCoverageMatrixMatchesPublicToolCatalog() {
        let server = ToolCatalog()

        XCTAssertEqual(
            Set(server.toolNames()),
            Set(CommandCoverageMatrix.publicToolNames),
            "Every public tool must declare contract coverage."
        )
    }

    func testAllPublicCoverageEntriesHaveAssertions() {
        for coverage in CommandCoverageMatrix.toolCommands + CommandCoverageMatrix.cliCommands {
            XCTAssertFalse(coverage.expectedAssertion.isEmpty, "Missing assertion for \(coverage.name)")
        }
    }

    func testAssistantToolCoverageEntriesAreProviderNeutral() {
        for toolName in CommandCoverageMatrix.aiToolNames {
            XCTAssertFalse(
                toolName.hasPrefix("ai_"),
                "Assistant tools must not use the removed ai_* prefix: \(toolName)"
            )
        }
    }

    func testReleaseBlockingToolNamesAreDeterministicAndBlocking() throws {
        let blockingNames = CommandCoverageMatrix.releaseBlockingToolNames
        XCTAssertFalse(blockingNames.isEmpty)
        XCTAssertTrue(blockingNames.contains("tap"))
        XCTAssertFalse(blockingNames.contains("device_boot"), "device_boot is informational, not release-blocking")

        for name in blockingNames {
            let coverage = try XCTUnwrap(CommandCoverageMatrix.coverage(for: name))
            XCTAssertEqual(coverage.releaseTier, .blocking)
            XCTAssertEqual(coverage.kind, .deterministic)
        }
    }

    func testCoverageLooksUpBothToolAndCLICommandsByName() throws {
        let toolCoverage = try XCTUnwrap(CommandCoverageMatrix.coverage(for: "tap"))
        XCTAssertEqual(toolCoverage.channel, .tool)

        let cliCoverage = try XCTUnwrap(CommandCoverageMatrix.coverage(for: "preflight"))
        XCTAssertEqual(cliCoverage.channel, .cli)

        XCTAssertNil(CommandCoverageMatrix.coverage(for: "does_not_exist"))
    }
}
