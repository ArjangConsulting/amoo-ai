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

    func testAssistantToolCoverageEntriesAreProviderNeutral() {
        for toolName in CommandCoverageMatrix.aiToolNames {
            XCTAssertFalse(toolName.hasPrefix("ai_"), "Assistant tools must not use the removed ai_* prefix: \(toolName)")
        }
    }
}
