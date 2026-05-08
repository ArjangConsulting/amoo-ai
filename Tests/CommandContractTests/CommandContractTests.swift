import CommandContract
import MCPServer
import XCTest

final class CommandContractTests: XCTestCase {
    func testCoverageMatrixMatchesPublicMCPToolCatalog() {
        let server = MCPServer()

        XCTAssertEqual(
            Set(server.toolNames()),
            Set(CommandCoverageMatrix.publicMCPToolNames),
            "Every public MCP tool must declare contract coverage."
        )
    }

    func testAllPublicCoverageEntriesHaveAssertions() {
        for coverage in CommandCoverageMatrix.mcpCommands + CommandCoverageMatrix.cliCommands {
            XCTAssertFalse(coverage.expectedAssertion.isEmpty, "Missing assertion for \(coverage.name)")
        }
    }

    func testAllAIToolCoverageEntriesAreCanonical() {
        for toolName in CommandCoverageMatrix.aiToolNames {
            XCTAssertTrue(toolName.hasPrefix("ai_"), "AI tools must use the ai_* prefix: \(toolName)")
        }
    }
}
