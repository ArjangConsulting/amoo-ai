@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

// swiftlint:disable multiline_arguments

final class InitAuditTests: InitTestCase {
    func testJSONUsageAndManifestErrorsAreSingleDocuments() async throws {
        for args in [
            ["--json", "--platform", "invalid"],
            ["down", "--json"],
            ["device", "--manifest", "/nonexistent/amoo-manifest.json", "--json"]
        ] {
            let result = await handleInitCommand(remaining: args)
            XCTAssertEqual(result.exitCode, 64)
            let manifest = try JSONDecoder().decode(InitManifest.self, from: Data(result.output.utf8))
            XCTAssertFalse(manifest.ok)
            XCTAssertNotNil(manifest.error)
        }
    }

    func testUnwritableManifestParentPreventsLeasing() async throws {
        let scratch = try makeScratchDirectory()
        let parent = scratch.url.appendingPathComponent("file")
        try Data().write(to: parent)
        let result = await runInit(
            InitOptions(
                environment: EnvUpOptions(),
                devices: ["phone"],
                out: parent.appendingPathComponent("state.json").path
            ),
            setup: forbidden("Cannot lease without a writable manifest")
        )
        XCTAssertEqual(result.exitCode, 1)
    }

    func testSaveFailureIsReportedInJSONWithLeasesPreserved() async throws {
        let scratch = try makeScratchDirectory()
        let result = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--json",
                "--save",
                "--agents-file",
                scratch.url.appendingPathComponent("missing/AGENTS.md").path
            ],
            runtime: runtime(discovery: discovery(devices: [candidate("phone")]), setup: succeedingSetup)
        )
        XCTAssertEqual(result.exitCode, 1)
        let manifest = try JSONDecoder().decode(InitManifest.self, from: Data(result.output.utf8))
        XCTAssertFalse(manifest.ok)
        XCTAssertEqual(manifest.results.first?.lease, "L")
        XCTAssertTrue(manifest.error?.contains("Could not save") == true)
    }

    func testEOFDuringSaveCancelsEvenWithYes() async throws {
        let scratch = try makeScratchDirectory()
        let prompter = ScriptedPrompter()
        prompter.confirms = [nil]
        let result = await runInitCommand(
            [
                "--platform",
                "ios",
                "--device",
                "phone",
                "--no-skills",
                "--yes",
                "--out",
                scratch.url.appendingPathComponent("state.json").path
            ],
            runtime: runtime(
                prompter: prompter, interactive: true,
                discovery: discovery(devices: [candidate("phone")]),
                setup: forbidden("EOF must cancel before leasing")
            )
        )
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Cancelled"))
    }

    func testFrameworkRoundTripsThroughSavedLocations() throws {
        let request = try parseInitRequest(["--framework", "react-native"])
        let saved = InitSavedLocations(platform: .ios, framework: request.framework)
        let block = renderInitLocationsBlock(saved, relativeTo: "/repo")
        XCTAssertEqual(parseInitLocations(from: block, relativeTo: "/repo")?.framework, "react-native")
        XCTAssertThrowsError(try parseInitRequest(["--framework", "unknown"]))
    }

    func testProfileWithWindowsLineEndingsLoads() throws {
        let scratch = try makeScratchDirectory()
        let profile = scratch.url.appendingPathComponent("amoo.md")
        try "test\r\n```amoo-context\r\n{\"baseClass\":\"AppTests\"}\r\n```\r\n"
            .write(to: profile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try RepositoryTestProfile.load(profile).baseClass, "AppTests")
    }
}

// swiftlint:enable multiline_arguments
