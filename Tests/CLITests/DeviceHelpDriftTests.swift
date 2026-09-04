@testable import CLI
import Foundation
import MCPServer
import XCTest

/// Guards `amoo device --help` against drifting away from the MCP tool schemas it documents.
///
/// The two listings used to be maintained by hand and independently, so `take_screenshot`'s
/// `output=` argument — implemented, schema-documented, and auto-filled by the REPL — was
/// invisible to anyone driving the CLI directly. These tests fail the build instead.
final class DeviceHelpDriftTests: XCTestCase {
    /// Tools deliberately left out of the CLI's "Common tools" listing: they either belong to the
    /// MCP session lifecycle (which `amoo device` does not manage — every call is one-shot) or are
    /// covered by a dedicated `amoo` subcommand.
    private static let intentionallyOmitted: Set<String> = [
        "start_session", "end_session", "list_sessions", "get_session_report",
        "compile_session_to_plan",
        "companion_warm", "companion_status",
        "list_apps",
        "navigate_to",
        "audit_app", "audit_accessibility", "audit_security",
        "device_boot", "device_shutdown"
    ]

    /// Arguments every listing may omit: `session_id` is bolted onto every driver-routed tool by
    /// `MCPServer`, and `amoo device` has no session to route to.
    private static let ignoredArguments: Set<String> = ["session_id"]

    func testEveryDocumentedArgumentMatchesATool() {
        let defined = Set(MCPServer().toolDefinitions().map(\.name))
        for entry in Self.helpEntries() {
            XCTAssertTrue(
                defined.contains(entry.tool),
                "amoo device --help lists '\(entry.tool)', which is not a registered MCP tool."
            )
        }
    }

    func testEveryToolArgumentIsDocumented() {
        let definitions = MCPServer().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })

        for entry in Self.helpEntries() {
            guard let definition = byName[entry.tool] else { continue }
            let undocumented = definition.properties.keys
                .filter { !Self.ignoredArguments.contains($0) && !entry.arguments.contains($0) }
                .sorted()
            XCTAssertTrue(
                undocumented.isEmpty,
                "amoo device --help documents '\(entry.tool)' without its \(undocumented.joined(separator: ", "))"
                    + " argument(s). Add them to deviceHelpUsageAndTools or the CLI hides a"
                    + " working feature."
            )
        }
    }

    func testEveryToolIsListedOrExplicitlyOmitted() {
        let listed = Set(Self.helpEntries().map(\.tool))
        let missing = MCPServer().toolDefinitions()
            .map(\.name)
            .filter { !listed.contains($0) && !Self.intentionallyOmitted.contains($0) }
            .sorted()

        XCTAssertTrue(
            missing.isEmpty,
            "New MCP tool(s) \(missing.joined(separator: ", ")) are reachable through `amoo device`"
                + " but absent from its --help. List them, or add them to intentionallyOmitted."
        )
    }

    // MARK: - Help parsing

    private struct HelpEntry {
        var tool: String
        var arguments: Set<String>
    }

    /// Parses the "Common tools:" block. An entry starts at two-space indentation and continues
    /// onto any line indented further, which is how the longer signatures wrap.
    private static func helpEntries() -> [HelpEntry] {
        let help = renderDeviceHelp()
        guard let start = help.range(of: "Common tools:\n"),
              let end = help.range(of: "\nCoordinates:", range: start.upperBound ..< help.endIndex)
        else {
            XCTFail("Could not locate the 'Common tools:' block in amoo device --help.")
            return []
        }

        var entries: [HelpEntry] = []
        for line in help[start.upperBound ..< end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if indent == 2 {
                let tool = String(trimmed.prefix { !$0.isWhitespace })
                entries.append(HelpEntry(tool: tool, arguments: argumentNames(in: trimmed)))
            } else if !entries.isEmpty {
                entries[entries.count - 1].arguments.formUnion(argumentNames(in: trimmed))
            }
        }
        return entries
    }

    /// Pulls the `name` out of every `name=<...>` occurrence in a signature line.
    private static func argumentNames(in line: String) -> Set<String> {
        var names: Set<String> = []
        for token in line.split(whereSeparator: { " []()".contains($0) }) {
            guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { continue }
            let name = token[token.startIndex ..< equals]
            if name.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) {
                names.insert(String(name))
            }
        }
        return names
    }
}
