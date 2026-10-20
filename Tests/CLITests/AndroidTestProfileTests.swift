@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import TestCommons
import XCTest

// swiftlint:disable multiline_arguments

final class AndroidTestProfileTests: XCTestCase {
    func testDiscoversKotlinAndJavaInstrumentationAndSkipsBuildOutputs() throws {
        let scratch = try makeScratchDirectory()
        try write("""
        package com.example
        import org.junit.Test
        import androidx.test.espresso.Espresso.onView
        open class BaseUiTest {}
        class LoginTest : BaseUiTest() {
            @Test fun login() { onView(withId(R.id.login)) }
        }
        """, to: "app/src/androidTest/kotlin/LoginTest.kt", root: scratch.url)
        try write("""
        package com.example;
        import org.junit.Test;
        import androidx.compose.ui.test.junit4.ComposeTestRule;
        public class OtherTest { @Test public void check() {} }
        """, to: "shared/src/androidInstrumentedTest/java/OtherTest.java", root: scratch.url)
        try write("import org.junit.Test", to: "build/src/androidTest/Generated.kt", root: scratch.url)
        try write("import org.junit.Test", to: "app/src/test/UnitTest.kt", root: scratch.url)
        try saveInitTestProfile(at: scratch.url)
        let file = scratch.url.appendingPathComponent("amoo.md")
        let context = try RepositoryTestProfile.load(file, platform: .android)
        XCTAssertEqual(context.targetPlatform, .android)
        XCTAssertEqual(context.baseClass, "com.example.BaseUiTest()")
        XCTAssertNil(try RepositoryTestProfile.discover(from: scratch.url, platform: .ios))
        let document = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(document.contains("Espresso"))
        XCTAssertTrue(document.contains("Jetpack Compose"))
        XCTAssertTrue(document.contains("R.id.login"))
        XCTAssertFalse(document.contains("Generated.kt"))
        XCTAssertFalse(document.contains("UnitTest.kt"))
    }

    func testMixedProfileSelectsPlatformAndPreservesReviewedContent() throws {
        let scratch = try makeScratchDirectory()
        try write(
            "import XCTest\nclass AppTests: XCTestCase { let app = XCUIApplication() }",
            to: "AppUITests.swift",
            root: scratch.url
        )
        try write(
            "import org.junit.Test\nclass LoginTest {}",
            to: "app/src/androidTest/LoginTest.kt",
            root: scratch.url
        )
        try saveInitTestProfile(at: scratch.url)
        let file = scratch.url.appendingPathComponent("amoo.md")
        XCTAssertEqual(try RepositoryTestProfile.load(file, platform: .ios).targetPlatform, .ios)
        XCTAssertEqual(try RepositoryTestProfile.load(file, platform: .android).targetPlatform, .android)
        XCTAssertThrowsError(try RepositoryTestProfile.load(file))
        let original = try Data(contentsOf: file)
        try saveInitTestProfile(at: scratch.url)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testReinitializationAppendsOnlyTheNewPlatform() throws {
        let scratch = try makeScratchDirectory()
        try write(
            "import XCTest\nclass AppTests: XCTestCase { let app = XCUIApplication() }",
            to: "AppUITests.swift",
            root: scratch.url
        )
        try saveInitTestProfile(at: scratch.url)
        let file = scratch.url.appendingPathComponent("amoo.md")
        let reviewed = try String(contentsOf: file, encoding: .utf8) + "\nReviewed launch conventions.\n"
        try reviewed.write(to: file, atomically: true, encoding: .utf8)
        try write("import org.junit.Test\nclass AppTest {}", to: "app/src/androidTest/AppTest.kt", root: scratch.url)
        try saveInitTestProfile(at: scratch.url)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(reviewed))
        XCTAssertEqual(try RepositoryTestProfile.load(file, platform: .android).targetPlatform, .android)
        let combined = try Data(contentsOf: file)
        try saveInitTestProfile(at: scratch.url)
        XCTAssertEqual(try Data(contentsOf: file), combined)
    }

    func testCompetingRuleDoesNotBecomeAnAutomaticBaseBinding() throws {
        let scratch = try makeScratchDirectory()
        try write("""
        package com.example
        import org.junit.Rule
        open class BaseTest {
            @get:Rule val rule = createAndroidComposeRule<MainActivity>()
        }
        class AppTest : BaseTest() {}
        """, to: "app/src/androidTest/AppTest.kt", root: scratch.url)
        try saveInitTestProfile(at: scratch.url)
        let file = scratch.url.appendingPathComponent("amoo.md")
        XCTAssertNil(try RepositoryTestProfile.load(file, platform: .android).baseClass)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("createAndroidComposeRule"))
    }

    func testAmbiguousAndWrongPlatformContextsAreRejected() throws {
        let scratch = try makeScratchDirectory()
        let file = scratch.url.appendingPathComponent("amoo.md")
        let block = "```amoo-context\n{\"targetPlatform\":\"ios\"}\n```\n"
        try block.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RepositoryTestProfile.load(file, platform: .android))
        try (block + block).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RepositoryTestProfile.load(file, platform: .ios))
    }

    func testExplicitMultiPlatformProfileSelectsPlanPlatform() throws {
        let emitters = StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        let test = StudioAuthoredTest(
            formatVersion: 1, name: "Profile", description: "", platform: .ios, steps: [],
            compiledPlan: .init(
                compiler: "test",
                compilerVersion: "1",
                toolOperations: [.init(id: "tap", tool: "tap_element", arguments: ["id": "submit"])]
            )
        )
        let plan = try makeScratchDirectory().url.appendingPathComponent("plan.json")
        try JSONEncoder().encode(test).write(to: plan)
        let profile = try makeScratchDirectory().url.appendingPathComponent("amoo.md")
        try """
        ```amoo-context
        {"targetPlatform":"ios","baseClass":"ReviewedIosTests"}
        ```
        ```amoo-context
        {"targetPlatform":"android","baseClass":"ReviewedAndroidTests()"}
        ```
        """.write(to: profile, atomically: true, encoding: .utf8)
        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(
                planPath: plan.path,
                outputDirectory: nil,
                contextPath: profile.path
            ),
            emitters: emitters
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains(": ReviewedIosTests"))
        XCTAssertFalse(result.output.contains("ReviewedAndroidTests"))
        try "This Markdown file is guidance, not a test context.".write(to: profile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: plan.path, outputDirectory: nil, contextPath: profile.path),
            emitters: emitters
        ))
        try JSONEncoder().encode(test.replacingTestContext(.init(targetPlatform: .android))).write(to: plan)
        XCTAssertThrowsError(try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: plan.path, outputDirectory: nil), emitters: emitters
        ))
    }

    private func write(_ source: String, to path: String, root: URL) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: file, atomically: true, encoding: .utf8)
    }
}

// swiftlint:enable multiline_arguments
