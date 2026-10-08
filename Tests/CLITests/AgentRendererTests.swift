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

    func testClaudeScopesTheMCPServerToTheSubagent() throws {
        let text = try render(.claude)
        XCTAssertTrue(text.hasPrefix("---\nname: amoo\ndescription: \"Drives \\\"devices\\\": iOS and Android.\"\n"))
        XCTAssertTrue(text.contains("model: sonnet"))
        XCTAssertTrue(text.contains("disallowedTools: Edit, NotebookEdit"))
        XCTAssertTrue(text
            .contains("mcpServers:\n  - amoo:\n      type: stdio\n      command: \"/tmp/local amoo/amoo\""))
        XCTAssertTrue(text.hasSuffix("---\n\nDo the thing.\n"))
    }

    func testDeviceVerifierKeepsItsToolAllowlistAndNoMCP() throws {
        let text = try AgentRenderer.render(source, definition: .deviceVerifier, for: .claude).contents
        XCTAssertTrue(text.contains("tools: Bash, Read, Write, Glob, Grep"))
        XCTAssertFalse(text.contains("mcpServers"))
    }

    func testCodexIsTOMLWithALiteralInstructionsBlockAndScopedServer() throws {
        let text = try render(.codex)
        XCTAssertTrue(text.contains("name = \"amoo\"\n"))
        XCTAssertTrue(text.contains("developer_instructions = '''\nDo the thing.\n'''\n"))
        XCTAssertTrue(text
            .contains("[mcp_servers.amoo]\ncommand = \"/tmp/local amoo/amoo\"\nargs = [\"mcp\", \"serve\"]"))
        let tableStart = try XCTUnwrap(text.range(of: "[mcp_servers.amoo]")).lowerBound
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "developer_instructions")).lowerBound, tableStart)
    }

    func testCodexRejectsABodyThatWouldEndTheLiteralString() {
        var unsafe = source
        unsafe.body = "use ''' here\n"
        XCTAssertThrowsError(try AgentRenderer.render(unsafe, definition: .amoo, for: .codex))
    }

    func testCopilotGeminiCursorAndOpenCodeFormats() throws {
        XCTAssertTrue(try render(.copilot).contains("mcp-servers:\n  amoo:\n    type: local"))
        XCTAssertFalse(try render(.copilot, mode: .plugin).contains("mcp-servers"))

        let gemini = try render(.gemini)
        XCTAssertTrue(gemini.contains("timeout_mins: 30"))
        XCTAssertTrue(gemini.contains("mcpServers:\n  amoo:\n    command: \"/tmp/local amoo/amoo\""))

        XCTAssertTrue(try render(.cursor).contains("model: inherit"))

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

    func testRejectsRelativeMCPBinary() {
        XCTAssertThrowsError(try AgentRenderer.render(
            source, definition: .amoo, for: .codex, executablePath: "amoo"
        ))
    }

    func testQuotedEscapesControlCharacters() {
        XCTAssertEqual(AgentRenderer.quoted("a\\b\n\u{1}"), "\"a\\\\b\\n\\u0001\"")
    }
}
