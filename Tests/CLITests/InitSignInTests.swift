@testable import CLI
import Foundation
import StudioProtocol
import XCTest

/// `amoo init` tells agents whether the repository can sign in by credential reference, and never
/// writes `amoo.config.json` itself.
final class InitSignInTests: XCTestCase {
    private func repository() throws -> URL {
        let root = try makeScratchDirectory().url
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return root
    }

    private func writeConfig(_ json: String, in root: URL) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent(AmooProjectConfig.fileName))
    }

    private let validConfig = """
    {"version": 1, "profiles": {"mock-user": {"apps": ["com.example.qa"],
      "fields": {"password": {"literal": "canary-INIT-551", "class": "secret"}}}}}
    """

    func testInspectReportsMissingInvalidAndConfigured() throws {
        let root = try repository()
        XCTAssertEqual(InitSignInStatus.inspect(root: root), .missing)

        try writeConfig(#"{"version": 1, "profiles": {"p": {"apps": [], "fields": {}}}}"#, in: root)
        guard case let .invalid(_, problem) = InitSignInStatus.inspect(root: root) else {
            return XCTFail("expected invalid")
        }
        XCTAssertTrue(problem.contains("lists no apps"))

        try writeConfig(validConfig, in: root)
        guard case let .configured(_, profiles) = InitSignInStatus.inspect(root: root) else {
            return XCTFail("expected configured")
        }
        XCTAssertEqual(profiles, ["mock-user"])
    }

    func testSavedBlockCarriesTheSignInLineAndStillRoundTrips() throws {
        let root = try repository()
        let agents = root.appendingPathComponent("AGENTS.md").path
        let saved = InitSavedLocations(
            platform: .android,
            appPath: nil,
            appID: "com.example.qa",
            manifestDirectory: nil
        )

        try saveInitLocations(saved, agentsFile: agents)
        var text = try String(contentsOfFile: agents, encoding: .utf8)
        XCTAssertTrue(text
            .contains("- Sign-in: no `amoo.config.json`; signed-in flows report `blocked: no credentials`"))

        try writeConfig(validConfig, in: root)
        try saveInitLocations(saved, agentsFile: agents)
        text = try String(contentsOfFile: agents, encoding: .utf8)
        XCTAssertTrue(text.contains("- Sign-in: profiles in `amoo.config.json`; pass `credential=<profile>#<field>`"))
        XCTAssertFalse(text.contains("no `amoo.config.json`"), "the block is replaced, not appended")
        XCTAssertFalse(text.contains("canary-INIT-551"))
        XCTAssertEqual(parseInitLocations(from: text, relativeTo: root.path), saved)
    }

    func testInitNeverCreatesTheConfig() throws {
        let root = try repository()
        try saveInitLocations(
            InitSavedLocations(platform: .ios, appPath: nil, appID: nil, manifestDirectory: nil),
            agentsFile: root.appendingPathComponent("AGENTS.md").path
        )
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: root.appendingPathComponent(AmooProjectConfig.fileName).path))
    }

    func testSummaryNamesProfilesOrExplainsHowToAddThem() {
        XCTAssertTrue(InitSignInStatus.missing.nextSteps.contains("amoo config --help"))
        XCTAssertTrue(InitSignInStatus.invalid(path: "/r/amoo.config.json", problem: "bad").nextSteps
            .contains("amoo config validate"))
        let configured = InitSignInStatus.configured(path: "/r/amoo.config.json", profiles: ["mock-user", "staging"])
        XCTAssertTrue(configured.nextSteps.contains("mock-user, staging"))
        XCTAssertTrue(configured.nextSteps.contains("credential=<profile>#<field>"))
    }

    func testConfigHelpShowsAProfileExample() {
        let help = renderConfigHelp()
        XCTAssertTrue(help.contains("\"profiles\""))
        XCTAssertTrue(help.contains("\"class\": \"secret\""))
    }
}
