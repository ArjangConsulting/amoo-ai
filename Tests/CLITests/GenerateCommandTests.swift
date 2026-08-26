import AmooCore
@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import XCTest

final class GenerateCommandTests: XCTestCase {
    private var emitters: StudioCodeEmitters {
        var result = StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        result.register(ComposeEspressoEmitter(), for: .init(platform: .android, toolkit: .compose))
        return result
    }

    private func writePlan(_ test: StudioAuthoredTest) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString).json")
        try JSONEncoder().encode(test).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    private func makeTest(warnings: [StudioPlanWarning]) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Tap submit", expected: "Signed in")],
            compiledPlan: .init(
                compiler: "session-compiler",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"])],
                warnings: warnings
            )
        )
    }

    func testGeneratesWhenThePlanCompiledCleanly() throws {
        let path = try writePlan(makeTest(warnings: []))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil),
            emitters: emitters
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("class SignInTest"))
    }

    func testRefusesToGenerateAnIncompleteTestAndNamesTheMissingSteps() throws {
        let path = try writePlan(makeTest(warnings: [
            .init(kind: .excluded, actionIndex: 2, toolName: "scroll", reason: "no Studio tool equivalent")
        ]))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil),
            emitters: emitters
        )

        // Silently emitting a shorter test is the failure this guards against — the user would
        // then debug a test that never contained the step they recorded.
        XCTAssertEqual(result.exitCode, 65)
        XCTAssertTrue(result.output.contains("scroll"), "should name the tool that went missing")
        XCTAssertTrue(result.output.contains("step 2"), "should name where it went missing")
        XCTAssertTrue(result.output.contains("--allow-incomplete"), "should say how to proceed anyway")
        XCTAssertFalse(result.output.contains("class SignInTest"), "must not emit code")
    }

    func testAllowIncompleteGeneratesAnyway() throws {
        let path = try writePlan(makeTest(warnings: [
            .init(kind: .excluded, actionIndex: 2, toolName: "scroll", reason: "no Studio tool equivalent")
        ]))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil, allowIncomplete: true),
            emitters: emitters
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("class SignInTest"))
    }

    func testNonExcludingWarningsDoNotBlockGeneration() throws {
        let path = try writePlan(makeTest(warnings: [
            .init(kind: .approximate, actionIndex: 0, toolName: "assert_visible", reason: "loose selector"),
            .init(kind: .notApplicable, actionIndex: 1, toolName: "find_elements", reason: "inspection only"),
            .init(kind: .redacted, actionIndex: 3, toolName: "set_text", reason: "redacted value")
        ]))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil),
            emitters: emitters
        )

        // Only dropped steps make a test incomplete. Blocking on the others would make the refusal
        // routine noise, and users would reflexively pass --allow-incomplete every time.
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("class SignInTest"))
    }

    func testPlansWrittenBeforeWarningsExistedStillGenerate() throws {
        let path = try writePlan(StudioAuthoredTest(
            formatVersion: 1,
            name: "Legacy",
            description: "",
            platform: .ios,
            steps: [],
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"])]
            )
        ))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil),
            emitters: emitters
        )

        XCTAssertEqual(result.exitCode, 0)
    }

    func testAllowIncompleteFlagParsesWithoutConsumingTheNextArgument() throws {
        let options = try parseGenerateTestOptions(args: ["--allow-incomplete", "--plan", "p.json", "--out", "dir"])

        XCTAssertEqual(options.planPath, "p.json")
        XCTAssertEqual(options.outputDirectory, "dir")
        XCTAssertTrue(options.allowIncomplete)
    }

    func testLegacyPlatformSpellingsStillDecode() throws {
        // Plans written by AI or by older versions spell the platform loosely. They must keep
        // working, since the whole point of typing the field was to stop *guessing*, not to
        // invalidate every plan already on disk.
        for spelling in ["iOS", "ios", "Android", "android", "android-emulator"] {
            let json = """
            {"formatVersion":1,"name":"Legacy","description":"","platform":"\(spelling)","steps":[],
             "compiledPlan":{"compiler":"ai","compilerVersion":"1",
             "toolOperations":[{"id":"op-1","tool":"press_back","arguments":{}}]}}
            """
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("legacy-\(UUID().uuidString).json")
            try Data(json.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try runGenerateTestCommand(
                options: GenerateTestOptions(planPath: url.path, outputDirectory: nil),
                emitters: emitters
            )
            XCTAssertEqual(result.exitCode, 0, "'\(spelling)' should still decode")
        }
    }

    func testUnrecognizedPlatformIsRejectedRatherThanGuessed() throws {
        let json = """
        {"formatVersion":1,"name":"Weird","description":"","platform":"web","steps":[],
         "compiledPlan":{"compiler":"ai","compilerVersion":"1",
         "toolOperations":[{"id":"op-1","tool":"press_back","arguments":{}}]}}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("weird-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        // Guessing a platform here would generate a test for the wrong OS.
        XCTAssertThrowsError(try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: url.path, outputDirectory: nil),
            emitters: emitters
        ))
    }

    func testUnregisteredToolkitFailsInsteadOfFallingBackToAnotherEmitter() throws {
        let path = try writePlan(makeTest(warnings: []))

        // Only the view emitters are registered here; asking for compose must not quietly emit
        // View-based code that cannot see a Compose UI — that is the original bug.
        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil, uiToolkit: .compose),
            emitters: StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        )

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("compose"))
        XCTAssertFalse(result.output.contains("class SignInTest"))
    }

    func testInvalidToolkitValueReportsTheAllowedValues() {
        XCTAssertThrowsError(try parseGenerateTestOptions(args: ["--plan", "p.json", "--ui-toolkit", "swiftui"])) {
            let message = String(describing: $0)
            XCTAssertTrue(message.contains("swiftui"), "should name the bad value")
            XCTAssertTrue(message.contains("compose"), "should list what is allowed")
        }
    }

    func testAllowIncompleteDefaultsToFalse() throws {
        let options = try parseGenerateTestOptions(args: ["--plan", "p.json"])

        XCTAssertFalse(options.allowIncomplete)
    }

    func testUIToolkitOverrideSelectsComposeEmitter() throws {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Compose Flow",
            description: "",
            platform: .android,
            steps: [],
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: "tap_element", arguments: ["id": "submit"])]
            )
        )
        let path = try writePlan(test)
        let options = try parseGenerateTestOptions(args: ["--plan", path, "--ui-toolkit", "compose"])
        let result = try runGenerateTestCommand(options: options, emitters: emitters)

        XCTAssertEqual(options.uiToolkit, .compose)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("createEmptyComposeRule"))
        XCTAssertFalse(result.output.contains("onView("))
    }
}
