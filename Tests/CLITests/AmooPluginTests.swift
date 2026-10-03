import AmooCore
@testable import CLI
import Foundation
import XCTest

/// Guards the distributable plugin in `plugins/amoo`: manifests every marketplace reads, the
/// committed generated agent files, and the Agent Skills naming rules.
final class AmooPluginTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var pluginRoot: URL {
        repoRoot.appendingPathComponent("plugins/amoo")
    }

    private func json(_ path: String, in root: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: (root ?? repoRoot).appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], path)
    }

    func testPluginManifestsAgreeOnNameAndVersion() throws {
        let versioned = [
            "plugin.json",
            ".claude-plugin/plugin.json",
            ".cursor-plugin/plugin.json",
            "gemini-extension.json"
        ]
        for path in versioned {
            XCTAssertEqual(try json(path, in: pluginRoot)["name"] as? String, "amoo", path)
        }
        for path in versioned {
            XCTAssertEqual(try json(path, in: pluginRoot)["version"] as? String, AmooVersion.current, path)
        }
        XCTAssertEqual(
            try json("plugin.json", in: pluginRoot)["$schema"] as? String,
            "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"
        )
    }

    func testMCPConfigsStartTheAmooServerFromPath() throws {
        for path in ["mcp.json", ".mcp.json"] {
            let servers = try XCTUnwrap(json(path, in: pluginRoot)["mcpServers"] as? [String: Any], path)
            let amoo = try XCTUnwrap(servers["amoo"] as? [String: Any], path)
            XCTAssertEqual(amoo["command"] as? String, "amoo")
            XCTAssertEqual(amoo["args"] as? [String], ["mcp", "serve"])
        }
    }

    func testMarketplacesPointAtThePluginDirectory() throws {
        let claude = try XCTUnwrap(json(".claude-plugin/marketplace.json")["plugins"] as? [[String: Any]])
        XCTAssertEqual(claude.first?["source"] as? String, "./plugins/amoo")

        let cursor = try XCTUnwrap(json(".cursor-plugin/marketplace.json")["plugins"] as? [[String: Any]])
        XCTAssertEqual(cursor.first?["source"] as? String, "plugins/amoo")

        let codex = try XCTUnwrap(json(".agents/plugins/marketplace.json")["plugins"] as? [[String: Any]])
        let source = try XCTUnwrap(codex.first?["source"] as? [String: Any])
        XCTAssertEqual(source["path"] as? String, "./plugins/amoo")

        for entries in [claude, cursor, codex] {
            XCTAssertEqual(entries.compactMap { $0["name"] as? String }, ["amoo"])
        }
    }

    func testCommittedGeneratedAgentFilesAreCurrent() throws {
        let sources = try AgentDefinition.all.map { definition in
            let text = try String(
                contentsOf: pluginRoot.appendingPathComponent(definition.sourcePath),
                encoding: .utf8
            )
            return try (AgentSource(parsing: text, file: definition.sourcePath), definition)
        }
        for file in try AgentRenderer.pluginFiles(sources) {
            let committed = try? String(contentsOf: pluginRoot.appendingPathComponent(file.path), encoding: .utf8)
            XCTAssertEqual(committed, file.contents, "\(file.path) is stale — run `make plugin`.")
        }
    }

    func testCanonicalAgentsCarryOnlyPortableFrontmatter() throws {
        for definition in AgentDefinition.all {
            let text = try String(contentsOf: pluginRoot.appendingPathComponent(definition.sourcePath), encoding: .utf8)
            let frontmatter = text.components(separatedBy: "---\n")[1]
            let keys = frontmatter.split(separator: "\n").compactMap { $0.split(separator: ":").first.map(String.init) }
            XCTAssertEqual(keys, ["name", "description"], definition.sourcePath)
            XCTAssertEqual(try AgentSource(parsing: text, file: definition.sourcePath).name, definition.name)
        }
    }

    func testSkillsFollowTheAgentSkillsSpec() throws {
        let skills = pluginRoot.appendingPathComponent("skills")
        let names = try FileManager.default.contentsOfDirectory(atPath: skills.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(names), Set(AgentDefinition.all.flatMap(\.skills)))
        for name in names {
            let text = try String(contentsOf: skills.appendingPathComponent("\(name)/SKILL.md"), encoding: .utf8)
            let source = try AgentSource(parsing: text, file: name)
            XCTAssertEqual(source.name, name, "a skill's name must match its directory")
            XCTAssertLessThanOrEqual(source.description.count, 1024)
            XCTAssertNotNil(name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression), name)
            XCTAssertFalse(text.contains("](../"), "\(name): relative links break once the skill is installed")
        }
    }
}
