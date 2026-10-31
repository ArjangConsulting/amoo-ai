import AmooCore
@testable import CLI
import Foundation
import XCTest

final class InitRepoDetectionTests: InitTestCase {
    private func touch(_ root: URL, _ paths: [String]) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data().write(to: url)
            }
        }
    }

    private func orchestrator(_ extra: [String] = []) throws -> URL {
        let root = try makeScratchDirectory().url
        try touch(root, ["iOS/Novalingo.xcodeproj/", "Android/settings.gradle.kts", "web-player/package.json"] + extra)
        return root
    }

    private func discoveryWithDetection() -> InitDiscovery {
        InitDiscovery(
            devices: { platform in [self.candidate(platform == .ios ? "phone" : "emulator")] },
            bundleID: { _, _ in nil },
            repos: { detectInitRepos(at: $0, platform: $1) }
        )
    }

    func testFindsTheDirectoryForEachPlatformInAnOrchestrator() throws {
        let root = try orchestrator()
        try """
        [submodule "iOS"]
        \tpath = iOS
        \turl = git@example.com:app/iOS.git
        [submodule "web-player"]
        \tpath = web-player
        """.write(to: root.appendingPathComponent(".gitmodules"), atomically: true, encoding: .utf8)
        XCTAssertEqual(detectInitRepos(at: root, platform: .ios), ["iOS"])
        XCTAssertEqual(detectInitRepos(at: root, platform: .android), ["Android"])
    }

    func testFindsReactNativeStyleSubdirectoriesWithoutSubmodules() throws {
        let root = try makeScratchDirectory().url
        try touch(root, ["ios/App.xcworkspace/", "android/settings.gradle", "package.json"])
        XCTAssertEqual(detectInitRepos(at: root, platform: .ios), ["ios"])
        XCTAssertEqual(detectInitRepos(at: root, platform: .android), ["android"])
    }

    func testSubmodulePathsBelowTheTopLevelAreFound() throws {
        let root = try makeScratchDirectory().url
        try touch(root, ["apps/ios/project.yml"])
        try "[submodule \"x\"]\n\tpath = apps/ios\n".write(
            to: root.appendingPathComponent(".gitmodules"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(detectInitRepos(at: root, platform: .ios), ["apps/ios"])
    }

    func testARootThatIsAlreadyAPlatformProjectHasNothingToChoose() throws {
        let root = try makeScratchDirectory().url
        try touch(root, ["App.xcodeproj/", "Tools/Other.xcodeproj/"])
        XCTAssertEqual(detectInitRepos(at: root, platform: .ios), [])
    }

    func testHiddenDependencyAndDeeperDirectoriesAreIgnored() throws {
        let root = try makeScratchDirectory().url
        try touch(root, [
            ".hidden/A.xcodeproj/", "node_modules/B.xcodeproj/", "build/C.xcodeproj/",
            "tools/deeper/D.xcodeproj/"
        ])
        XCTAssertEqual(detectInitRepos(at: root, platform: .ios), [])
    }

    func testGuidedFlowConfirmsASingleDetectedRepositoryAndDefaultsTheManifestInsideIt() async throws {
        let root = try orchestrator()
        let prompter = ScriptedPrompter()
        let request = InitRequest(platform: .ios, framework: "native", devices: ["phone"], launch: false)
        let completed = try await completeInitRequest(
            request, discovery: discoveryWithDetection(), prompter: prompter, root: root
        )
        XCTAssertEqual(completed.repo, "iOS")
        XCTAssertEqual(completed.out, root.appendingPathComponent("iOS/.amoo.json").path)
        XCTAssertTrue(prompter.transcript.contains { $0.hasPrefix("Found iOS/.") }, prompter.transcript.joined())
    }

    func testDecliningTheDetectedRepositoryKeepsTheRootAsTheRepository() async throws {
        let root = try orchestrator()
        let prompter = ScriptedPrompter()
        prompter.confirms = [false]
        let request = InitRequest(platform: .ios, framework: "native", devices: ["phone"], launch: false)
        let completed = try await completeInitRequest(
            request, discovery: discoveryWithDetection(), prompter: prompter, root: root
        )
        XCTAssertNil(completed.repo)
        XCTAssertTrue(completed.out?.hasSuffix("/.amoo.json") ?? false)
        XCTAssertFalse(completed.out?.contains("/iOS/") ?? true)
    }

    func testSeveralCandidatesAreChosenFromAListThatOffersTheRoot() async throws {
        let root = try orchestrator(["Clips/Clips.xcodeproj/"])
        let prompter = ScriptedPrompter()
        prompter.choices = [1]
        let request = InitRequest(platform: .ios, framework: "native", devices: ["phone"], launch: false)
        let completed = try await completeInitRequest(
            request, discovery: discoveryWithDetection(), prompter: prompter, root: root
        )
        XCTAssertEqual(completed.repo, "iOS")
        let question = try XCTUnwrap(prompter.transcript.first { $0.hasPrefix("Which directory holds the iOS app?") })
        XCTAssertTrue(question.contains("Clips | iOS | This directory"), question)
    }

    func testBothPlatformsGetTheirOwnRepositoryAndManifest() async throws {
        let root = try orchestrator()
        let prompter = ScriptedPrompter()
        prompter.choices = [2, 0]
        prompter.multi = [[0], [0]]
        let completed = try await completeInitRequest(
            InitRequest(), discovery: discoveryWithDetection(), prompter: prompter, root: root
        )
        let android = try XCTUnwrap(completed.additionalRequests.first)
        XCTAssertEqual(completed.repo, "iOS")
        XCTAssertEqual(android.repo, "Android")
        XCTAssertEqual(completed.out, root.appendingPathComponent("iOS/.amoo.json").path)
        XCTAssertEqual(android.out, root.appendingPathComponent("Android/.amoo.json").path)
    }

    func testHeadlessRefusalNamesTheDetectedRepositories() async throws {
        let root = try orchestrator()
        let result = await runInitCommand(
            ["--platform", "ios", "--agents-file", root.appendingPathComponent("AGENTS.md").path, "--non-interactive"],
            runtime: runtime(discovery: discoveryWithDetection(), setup: forbidden("must not start"))
        )
        XCTAssertEqual(result.exitCode, 64, result.output)
        XCTAssertTrue(result.output.contains("Detected ios repositories: --repo iOS"), result.output)
    }
}
