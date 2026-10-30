import AmooCore
@testable import CLI
import Foundation
import StudioProtocol
import XCTest

final class InitRepoTests: InitTestCase {
    private func orchestrator() throws -> URL {
        let root = try makeScratchDirectory().url.appendingPathComponent("mobile")
        for directory in ["iOS", "Android", ".git"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    func testRepoFlagNeedsAPlatformAndStaysInsideTheRepository() throws {
        XCTAssertEqual(try parseInitRequest(["--platform", "ios", "--repo", "iOS"]).repo, "iOS")
        XCTAssertThrowsError(try parseInitRequest(["--repo", "iOS"]))
        for escaping in ["/tmp/x", "../x", "a/../../x", "~/x", ""] {
            XCTAssertThrowsError(try parseInitRequest(["--platform", "ios", "--repo", escaping]), escaping)
        }
    }

    func testSavedLocationsRoundTripTheRepoOfEachPlatform() {
        let saved = InitSavedLocations(
            platform: .ios,
            repoPath: "iOS",
            additionalLocations: [InitSavedLocations(platform: .android, repoPath: "Android")]
        )
        let block = renderInitLocationsBlock(saved, relativeTo: "/root")
        XCTAssertTrue(block.contains("- Repo: `iOS`"), block)
        let parsed = parseInitLocations(from: block, relativeTo: "/root")
        XCTAssertEqual(parsed?.forPlatform(.ios)?.repoPath, "iOS")
        XCTAssertEqual(parsed?.forPlatform(.android)?.repoPath, "Android")
    }

    func testRecordingTheRepoCreatesOrAppendsButNeverRewritesAReviewedBlock() throws {
        let root = try orchestrator()
        XCTAssertNil(try recordInitRepo(at: root, platform: .ios, repo: "iOS"))
        XCTAssertNil(try recordInitRepo(at: root, platform: .android, repo: "Android"))
        XCTAssertEqual(try RepositoryTestProfile.repositoryDirectory(for: .ios, from: root)?.lastPathComponent, "iOS")
        XCTAssertEqual(
            try RepositoryTestProfile.repositoryDirectory(for: .android, from: root)?.lastPathComponent,
            "Android"
        )
        let before = try String(contentsOf: root.appendingPathComponent("amoo.md"), encoding: .utf8)
        XCTAssertNil(try recordInitRepo(at: root, platform: .ios, repo: "iOS"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("amoo.md"), encoding: .utf8), before)

        let reviewed = try orchestrator()
        let text = "```amoo-context\n{\"targetPlatform\":\"ios\",\"baseClass\":\"Mine\"}\n```\n"
        try text.write(to: reviewed.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        let note = try recordInitRepo(at: reviewed, platform: .ios, repo: "iOS")
        XCTAssertTrue(note?.contains("\"repo\": \"iOS\"") ?? false, note ?? "nil")
        XCTAssertEqual(try String(contentsOf: reviewed.appendingPathComponent("amoo.md"), encoding: .utf8), text)

        let unscoped = try orchestrator()
        try "```amoo-context\n{\"baseClass\":\"Shared\"}\n```\n"
            .write(to: unscoped.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(try recordInitRepo(at: unscoped, platform: .ios, repo: "iOS"))
    }

    func testDiscoveryFromTheRootLayersTheDeclaredRepositoryProfile() throws {
        let root = try orchestrator()
        try """
        ```amoo-context
        {"targetPlatform":"ios","repo":"iOS","baseClass":"Shared","imports":["Shared"]}
        ```
        """.write(to: root.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        try """
        ```amoo-context
        {"targetPlatform":"ios","baseClass":"NovaTestCase"}
        ```
        """.write(to: root.appendingPathComponent("iOS/amoo.md"), atomically: true, encoding: .utf8)
        let fromRoot = try XCTUnwrap(RepositoryTestProfile.discover(from: root, platform: .ios))
        XCTAssertEqual(fromRoot.baseClass, "NovaTestCase")
        XCTAssertEqual(fromRoot.imports, ["Shared"])
        XCTAssertEqual(fromRoot.repo, "iOS")
        let fromInside = try XCTUnwrap(RepositoryTestProfile.discover(
            from: root.appendingPathComponent("iOS"),
            platform: .ios
        ))
        XCTAssertEqual(fromInside, fromRoot)
        XCTAssertNil(try RepositoryTestProfile.discover(from: root, platform: .android))
    }

    func testARepoThatEscapesTheRepositoryIsRejected() throws {
        let root = try orchestrator()
        try "```amoo-context\n{\"targetPlatform\":\"ios\",\"repo\":\"../elsewhere\"}\n```\n"
            .write(to: root.appendingPathComponent("amoo.md"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RepositoryTestProfile.discover(from: root, platform: .ios))
    }

    func testHeadlessRepoInitWritesPlatformFilesInsideTheRepositoryAndRecordsItAtTheRoot() async throws {
        let root = try orchestrator()
        let agents = root.appendingPathComponent("AGENTS.md").path
        let result = await runInitCommand(
            [
                "--platform", "ios", "--device", "phone", "--repo", "iOS", "--save", "--no-skills",
                "--agents-file", agents, "--non-interactive", "--json"
            ],
            runtime: runtime(discovery: discovery(devices: [candidate("phone")]), setup: succeedingSetup)
        )
        XCTAssertEqual(result.exitCode, 0, result.output)
        let manifest = root.appendingPathComponent("iOS/.amoo.json")
        XCTAssertEqual(try InitManifest.read(manifest.path).results.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".amoo.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("iOS/amoo.md").path))
        XCTAssertTrue(try String(contentsOfFile: agents, encoding: .utf8).contains("- Repo: `iOS`"))
        XCTAssertEqual(try RepositoryTestProfile.repositoryDirectory(for: .ios, from: root)?.lastPathComponent, "iOS")
        XCTAssertEqual(
            discoverInitManifests(from: root).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            [manifest.resolvingSymlinksInPath().path]
        )
    }

    func testRepoThatDoesNotExistStopsBeforeAnyDevice() async throws {
        let root = try orchestrator()
        let result = await runInitCommand(
            [
                "--platform", "ios", "--device", "phone", "--repo", "Nope",
                "--agents-file", root.appendingPathComponent("AGENTS.md").path, "--non-interactive", "--json"
            ],
            runtime: runtime(discovery: discovery(devices: [candidate("phone")]), setup: forbidden("must not start"))
        )
        XCTAssertEqual(result.exitCode, 64, result.output)
    }

    func testDownResultsFromSeveralManifestsCombineIntoOneReport() throws {
        func report(_ runtime: String) -> CLIResult {
            let entry = renderJSON(EnvDownReport(ok: true, runtimeID: runtime, companionStopped: true, shutdown: false))
            return CLIResult(output: "{\"ok\":true,\"results\":[\(entry)]}", exitCode: 0)
        }
        XCTAssertEqual(combineInitDownResults([report("a")]).output, report("a").output)
        let combined = combineInitDownResults([report("a"), report("b")])
        XCTAssertEqual(combined.exitCode, 0)
        struct Envelope: Decodable {
            var ok: Bool
            var results: [EnvDownReport]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(combined.output.utf8))
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.results.compactMap(\.runtimeID), ["a", "b"])
        let failed = CLIResult(output: "not json", exitCode: 1)
        XCTAssertEqual(combineInitDownResults([report("a"), failed]).exitCode, 1)
    }
}
