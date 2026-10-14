@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

final class InitTestProfileTests: XCTestCase {
    func testDiscoversHarnessAndWritesOnlyMarkdownWithoutReplacingReviewedProfile() throws {
        let scratch = try makeScratchDirectory()
        let source = scratch.url.appendingPathComponent("JotUITests.swift")
        try """
        import XCTest
        import JotUIIdentifiers
        class JotUITestCase: XCTestCase {
            var app: XCUIApplication!
            func setUp() { app.launch() }
            func makeApplication() -> XCUIApplication { XCUIApplication() }
            func waitForExistence(_ element: XCUIElement, timeout: TimeInterval = UITestConstants.timeout) {}
        }
        class HabitTests: JotUITestCase {}
        enum JotUIAutomationID {
            enum Tab {
                static let habits = "habits"
            }
        }

        """.write(to: source, atomically: true, encoding: .utf8)
        try saveInitTestProfile(at: scratch.url)
        let profile = scratch.url.appendingPathComponent("amoo.md")
        let context = try RepositoryTestProfile.load(profile)
        XCTAssertEqual(context.targetPlatform, .ios)
        XCTAssertNil(try RepositoryTestProfile.discover(from: scratch.url, platform: .android))
        XCTAssertEqual(context.baseClass, "JotUITestCase")
        XCTAssertTrue(context.harnessOwnsApp)
        XCTAssertTrue(context.harnessLaunchesApp)
        XCTAssertEqual(context.imports, ["JotUIIdentifiers"])
        XCTAssertEqual(context.timeoutExpressions["default"], "UITestConstants.timeout")
        XCTAssertEqual(context.waitBindings["waitForExistence"], "waitForExistence({{element}})")
        XCTAssertEqual(context.selectorExpressions["habits"], "JotUIAutomationID.Tab.habits")
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: scratch.url.path)),
            ["JotUITests.swift", "amoo.md"]
        )
        try "Reviewed profile".write(to: profile, atomically: true, encoding: .utf8)
        try saveInitTestProfile(at: scratch.url)
        XCTAssertEqual(try String(contentsOf: profile, encoding: .utf8), "Reviewed profile")
    }

    func testNearestProfileIsLoadedAndMalformedProfileIsRejected() throws {
        let scratch = try makeScratchDirectory()
        let child = scratch.url.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let profile = scratch.url.appendingPathComponent("amoo.md")
        try """
        # Integration
        ```amoo-context
        {"baseClass":"JotUITestCase","harnessOwnsApp":true}
        ```
        """.write(to: profile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try RepositoryTestProfile.discover(from: child)?.baseClass, "JotUITestCase")
        try "No bindings".write(to: profile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RepositoryTestProfile.discover(from: child))
    }
}
