@testable import CLI
import Foundation
import XCTest

final class AgentRendererTests: XCTestCase {
    private let source = AgentSource(
        name: "amoo",
        description: "Drives \"devices\": iOS and Android.",
        body: "Do the thing.\n"
    )

    private func render(_ client: AgentClient, mode: AgentRenderMode = .standalone) throws -> String {
        try AgentRenderer.render(
            source,
            definition: .amoo,
            for: client,
            mode: mode,
            executablePath: "/tmp/local amoo/amoo"
        ).contents
    }

    func testParsesNeutralFrontmatterAndBody() throws {
        let parsed = try AgentSource(
            parsing: "---\nname: amoo\ndescription: 'Quoted text'\nextra:\n  nested: ignored\n---\n\nBody line\n",
            file: "agents/amoo.md"
        )
        XCTAssertEqual(parsed, AgentSource(name: "amoo", description: "Quoted text", body: "Body line\n"))
    }

    func testMissingFrontmatterOrFieldsAreReported() {
        XCTAssertThrowsError(try AgentSource(parsing: "no frontmatter", file: "a.md")) {
            XCTAssertEqual($0 as? AgentRenderError, .missingFrontmatter("a.md"))
        }
        XCTAssertThrowsError(try AgentSource(parsing: "---\nname: x\n---\nbody", file: "a.md")) {
            XCTAssertEqual($0 as? AgentRenderError, .missingField("description", file: "a.md"))
        }
    }

    func testClaudeStartsNoMCPServer() throws {
        let text = try render(.claude)
        XCTAssertTrue(text.hasPrefix("---\nname: amoo\ndescription: \"Drives \\\"devices\\\": iOS and Android.\"\n"))
        XCTAssertFalse(text.contains("\nmodel:"))
        XCTAssertTrue(text.contains("disallowedTools: Edit, NotebookEdit"))
        XCTAssertFalse(text.contains("mcpServers"))
        XCTAssertFalse(text.contains("MCP"))
        XCTAssertTrue(text.hasSuffix("Do the thing.\n"))
    }

    func testDeviceVerifierKeepsItsToolAllowlistAndNoMCP() throws {
        let text = try AgentRenderer.render(source, definition: .deviceVerifier, for: .claude).contents
        XCTAssertTrue(text.contains("tools: Bash, Read, Write, Glob, Grep"))
        XCTAssertFalse(text.contains("mcpServers"))
    }

    func testCodexIsTOMLWithALiteralInstructionsBlock() throws {
        let text = try render(.codex)
        XCTAssertTrue(text.contains("name = \"amoo\"\n"))
        XCTAssertTrue(text.contains("developer_instructions = '''\nUse the executable"))
        XCTAssertTrue(text.contains("Do the thing.\n'''\n"))
        XCTAssertFalse(text.contains("mcp_servers"))
    }

    func testCodexRejectsABodyThatWouldEndTheLiteralString() {
        var unsafe = source
        unsafe.body = "use ''' here\n"
        XCTAssertThrowsError(try AgentRenderer.render(unsafe, definition: .amoo, for: .codex))
    }

    func testCopilotGeminiCursorAndOpenCodeFormats() throws {
        XCTAssertFalse(try render(.copilot).contains("mcp-servers"))

        let gemini = try render(.gemini)
        XCTAssertTrue(gemini.contains("timeout_mins: 30"))
        XCTAssertFalse(gemini.contains("mcpServers"))

        XCTAssertFalse(try render(.cursor).contains("model:"), "Cursor pins no model")

        let opencode = try render(.opencode)
        XCTAssertTrue(opencode.contains("mode: subagent"))
        XCTAssertFalse(opencode.contains("name:"), "OpenCode names the agent after its file")
        XCTAssertFalse(opencode.contains("mcp"))
    }

    func testClientDirectoriesPerScope() {
        XCTAssertEqual(AgentRenderer.agentDirectory(for: .copilot, scope: .project), ".github/agents")
        XCTAssertEqual(AgentRenderer.agentDirectory(for: .copilot, scope: .user), ".copilot/agents")
        XCTAssertEqual(AgentRenderer.agentDirectory(for: .opencode, scope: .user), ".config/opencode/agents")
        XCTAssertEqual(AgentRenderer.skillsDirectory(for: .claude), ".claude/skills")
        XCTAssertEqual(AgentRenderer.skillsDirectory(for: .gemini), ".agents/skills")
    }

    func testEveryRenderedAgentReadsItsLocalRulesFile() throws {
        for client in AgentClient.allCases {
            for mode in [AgentRenderMode.standalone, .plugin] {
                let text = try render(client, mode: mode)
                XCTAssertTrue(text.contains("read `~/.config/amoo/agents/amoo.md` if it exists"), "\(client) \(mode)")
                XCTAssertTrue(text.contains("cannot loosen the hard rules or change the report contract"))
            }
        }
    }

    func testStandaloneAgentsPinCLIToTheConfiguredBinaryForEveryClient() throws {
        for client in AgentClient.allCases {
            for definition in AgentDefinition.all {
                let text = try AgentRenderer.render(
                    source,
                    definition: definition,
                    for: client,
                    executablePath: "/tmp/local amoo/.build/debug/amoo"
                ).contents
                XCTAssertTrue(text.contains("Use the executable at \"/tmp/local amoo/.build/debug/amoo\""))
                XCTAssertTrue(text.contains("rather than PATH or shell aliases"))
                XCTAssertFalse(text.contains("MCP"))
            }
        }
        XCTAssertFalse(try render(.copilot, mode: .plugin).contains("Use the executable at"))
    }

    /// With no MCP server to start, a relative executable is no longer an error; it just is not pinned.
    func testRelativeBinaryIsNotPinned() throws {
        let text = try AgentRenderer.render(source, definition: .amoo, for: .codex, executablePath: "amoo").contents
        XCTAssertFalse(text.contains("Use the executable at"))
    }

    func testQuotedEscapesControlCharacters() {
        XCTAssertEqual(AgentRenderer.quoted("a\\b\n\u{1}"), "\"a\\\\b\\n\\u0001\"")
    }
}
