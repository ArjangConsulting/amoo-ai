@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

final class InitAccessibilityTests: XCTestCase {
    private func repository() throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: ".git"), withIntermediateDirectories: true
        )
        return scratch
    }

    func testFlagsParseListsAllAndNoneAndRejectUnknownNames() throws {
        let request = try parseInitRequest([
            "--accessibility-checks", "names,contrast", "--accessibility-configurations", "dark_mode"
        ])
        XCTAssertEqual(request.accessibilityChecks, [.names, .contrast])
        XCTAssertEqual(request.accessibilityConfigurations, [.darkMode])
        XCTAssertEqual(try parseInitRequest(["--accessibility-checks", "all"]).accessibilityChecks?.count, 7)
        XCTAssertEqual(try parseInitRequest(["--accessibility-checks", "none"]).accessibilityChecks, [])
        XCTAssertThrowsError(try parseInitRequest(["--accessibility-checks", "colour"]))
    }

    func testGuidedQuestionsPreselectNothingForANewProject() {
        let prompter = ScriptedPrompter()
        prompter.multi = [[0, 2], [0]]
        let chosen = askInitAccessibilityPolicy(current: AccessibilityCheckPolicy(), prompter: prompter)
        XCTAssertEqual(chosen.enabledChecks, [.names, .contrast])
        XCTAssertEqual(chosen.enabledConfigurations, [.darkMode])
        XCTAssertEqual(prompter.multiDefaults.first, [], "Every accessibility check is opt-in")
    }

    func testChoosingNoChecksSkipsTheConfigurationQuestion() {
        let prompter = ScriptedPrompter()
        prompter.multi = [[]]
        let chosen = askInitAccessibilityPolicy(current: AccessibilityCheckPolicy(), prompter: prompter)
        XCTAssertTrue(chosen.enabledChecks.isEmpty)
        XCTAssertEqual(prompter.multiDefaults.count, 1)
    }

    func testDecliningInANewProjectWritesNothingAndOptingInSaves() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        let file = scratch.url.appending(path: AmooProjectConfig.fileName)
        XCTAssertNil(applyInitAccessibilityPolicy(
            AccessibilityCheckPolicy(),
            current: .notConfigured,
            root: scratch.url
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let policy = AccessibilityCheckPolicy(checks: [.targetSize], configurations: [.largeText])
        let note = try XCTUnwrap(applyInitAccessibilityPolicy(policy, current: .notConfigured, root: scratch.url))
        XCTAssertTrue(note.contains("target_size; repeated in large_text"), note)
        XCTAssertEqual(AccessibilityCheckResolution.resolve(from: scratch.url).policy.enabledChecks, [.targetSize])
    }

    func testHeadlessFlagsSaveWithoutAsking() throws {
        let scratch = try repository()
        defer { try? scratch.remove() }
        let prompter = ScriptedPrompter()
        let request = try parseInitRequest(["--accessibility-checks", "contrast"])
        XCTAssertNotNil(settleInitAccessibility(request, interactive: false, root: scratch.url, prompter: prompter))
        XCTAssertTrue(prompter.transcript.isEmpty)
        XCTAssertEqual(AccessibilityCheckResolution.resolve(from: scratch.url).policy.enabledChecks, [.contrast])
    }

    func testAgentsBlockTellsAgentsToRunTheChecks() {
        let block = renderInitLocationsBlock(
            InitSavedLocations(platform: .ios),
            relativeTo: "/repo",
            accessibility: .configured(AccessibilityCheckPolicy(checks: [.names], configurations: [.darkMode]))
        )
        let expected = "run `check_accessibility` on each screen you verify (names; repeated in dark_mode"
        XCTAssertTrue(block.contains(expected), block)
        let none = renderInitLocationsBlock(InitSavedLocations(platform: .ios), relativeTo: "/repo")
        XCTAssertFalse(none.contains("check_accessibility"))
    }
}
