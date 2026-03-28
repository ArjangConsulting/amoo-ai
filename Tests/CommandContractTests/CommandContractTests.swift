import CommandContract
import MCPServer
import XCTest

final class CommandContractTests: XCTestCase {
    func testCoverageMatrixMatchesPublicMCPToolCatalog() {
        let server = MCPServer()

        XCTAssertEqual(
            Set(server.toolNames()),
            Set(CommandCoverageMatrix.publicMCPToolNames + Array(CommandCoverageMatrix.deprecatedAIAliases.keys)),
            "Every public MCP tool must declare contract coverage."
        )
    }

    func testAllPublicCoverageEntriesHaveAssertions() {
        for coverage in CommandCoverageMatrix.mcpCommands + CommandCoverageMatrix.cliCommands {
            XCTAssertFalse(coverage.expectedAssertion.isEmpty, "Missing assertion for \(coverage.name)")
        }
    }

    func testAllAIAliasesPointToKnownCanonicalTools() {
        for (alias, canonical) in CommandCoverageMatrix.deprecatedAIAliases {
            XCTAssertNotNil(
                CommandCoverageMatrix.coverage(for: canonical),
                "Missing coverage for canonical tool \(canonical)"
            )
            XCTAssertFalse(alias.isEmpty)
        }
    }
}
