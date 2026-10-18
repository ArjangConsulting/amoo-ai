@testable import CLI
import Foundation
import StudioProtocol
import TestCommons
import XCTest

/// What `amoo init --save` captures for recording and export beyond the harness itself: the
/// language/locale/text-size flags the tests launch with, the Swift language mode and base-class
/// isolation, and the app's bundle identifier.
final class InitProjectFactsTests: XCTestCase {
    private static let selectionTests = """
    import XCTest
    class SelectionUITests: SampleUITestCase {
        private func configured() -> XCUIApplication {
            let app = sampleApplication()
            app.launchArguments = [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
                "-CalendarScrollMode", "vertical"
            ]
            return app
        }
    }

    """

    private static let dynamicTypeTests = """
    import XCTest
    class DynamicTypeUITests: SampleUITestCase {
        private static let sizeFlag = "-UIPreferredContentSizeCategoryName"
        func launch(size: String) {
            let app = sampleApplication()
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
            app.launchArguments += [Self.sizeFlag, size]
        }
    }

    """

    private static let support = """
    import XCTest
    class SampleUITestCase: XCTestCase {
        func sampleApplication() -> XCUIApplication { XCUIApplication() }
    }

    """

    private static let project = """
    {
      "targets": [
        { "settings": { "PRODUCT_BUNDLE_IDENTIFIER": "com.example.SwiftUICalendarSample", "SWIFT_VERSION": "6.4" } },
        { "settings": { "PRODUCT_BUNDLE_IDENTIFIER": "com.example.SampleUITests", "SWIFT_VERSION": "6.4" } },
        { "settings": { "PRODUCT_BUNDLE_IDENTIFIER": "$(inherited).extension" } }
      ]
    }

    """

    private func repository(_ files: [String: String]) throws -> URL {
        let scratch = try makeScratchDirectory().url
        for (path, text) in files {
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return scratch
    }

    private func facts(_ files: [String: String], baseClass: String? = "SampleUITestCase") throws -> InitProjectFacts {
        let root = try repository(files)
        let tests = files.keys.filter { $0.hasSuffix("UITests.swift") || $0.hasSuffix("Case.swift") }.sorted()
        return discoverInitProjectFacts(root: root, testFiles: tests, baseClass: baseClass)
    }

    // MARK: - Launch configuration

    func testLocaleAndTextSizeFlagsAreSeededAndScenarioFlagsAreNot() throws {
        let found = try facts([
            "UITests/SelectionUITests.swift": Self.selectionTests,
            "UITests/SampleUITestCase.swift": Self.support
        ])
        XCTAssertEqual(
            found.launchArguments,
            [
                "-AppleLanguages",
                "(en)",
                "-AppleLocale",
                "en_US",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryL"
            ]
        )
        XCTAssertFalse(found.launchArguments.contains("-CalendarScrollMode"), "a scenario switch is not seeded")
        XCTAssertEqual(found.launchSites.first?.path, "UITests/SelectionUITests.swift")
        XCTAssertEqual(found.launchSites.first?.line, 5)
    }

    func testAFlagSetToDifferentValuesOrThroughAVariableIsListedNotSeeded() throws {
        let conflicting = """
        import XCTest
        class OtherUITests: SampleUITestCase {
            func run() {
                let app = sampleApplication()
                app.launchArguments = ["-AppleLocale", "fr_FR"]
            }
        }

        """
        let found = try facts([
            "UITests/SelectionUITests.swift": Self.selectionTests,
            "UITests/OtherUITests.swift": conflicting,
            "UITests/DynamicTypeUITests.swift": Self.dynamicTypeTests
        ])
        XCTAssertFalse(found.launchArguments.contains("-AppleLocale"))
        XCTAssertTrue(found.undecidedFlags.contains("-AppleLocale"))
        XCTAssertTrue(found.launchArguments.contains("-AppleLanguages"), "the flag everyone agrees on is kept")
    }

    func testEnvironmentIsReportedButNeverSeeded() throws {
        let found = try facts(["UITests/DynamicTypeUITests.swift": Self.dynamicTypeTests])
        XCTAssertEqual(found.launchEnvironment, ["OS_ACTIVITY_MODE": "disable"])
        XCTAssertTrue(found.launchArguments.isEmpty)
        XCTAssertTrue(found.markdown().contains("never seeded"))
    }

    // MARK: - Concurrency and identifiers

    func testSwiftModeBaseClassIsolationAndAppIdentifierAreCaptured() throws {
        let found = try facts([
            "UITests/SampleUITestCase.swift": Self.support,
            "App.xcodeproj/project.xcproj": Self.project
        ])
        XCTAssertEqual(found.swiftLanguageModes, ["6.4 (App.xcodeproj/project.xcproj)"])
        XCTAssertEqual(found.baseClassMainActor, false)
        XCTAssertEqual(found.appIdentifiers, ["com.example.SwiftUICalendarSample"], "tests and variables are excluded")
        let markdown = found.markdown()
        XCTAssertTrue(markdown.contains("not main-actor isolated"), markdown)
        XCTAssertTrue(markdown.contains("async `setUp()`"), markdown)
        XCTAssertTrue(markdown.contains("`com.example.SwiftUICalendarSample`"), markdown)
    }

    func testAnIsolatedBaseClassIsRecognised() throws {
        let isolated = """
        import XCTest
        @MainActor
        open class SampleUITestCase: XCTestCase {}

        """
        let found = try facts(["UITests/SampleUITestCase.swift": isolated])
        XCTAssertEqual(found.baseClassMainActor, true)
    }

    func testPackageManifestEvidenceAndBuildDirectoriesAreHandled() throws {
        let found = try facts([
            "Package.swift": "// swift-tools-version: 6.2\nlet package = Package(swiftLanguageModes: [.v6])",
            ".build/checkouts/Dep/Package.swift": "// swift-tools-version: 4.0",
            "build/App.xcodeproj/project.pbxproj": "PRODUCT_BUNDLE_IDENTIFIER = com.build.artifact;"
        ])
        XCTAssertTrue(found.swiftLanguageModes.contains("swift-tools-version 6.2 (Package.swift)"))
        XCTAssertTrue(found.swiftLanguageModes.contains("language mode .v6 (Package.swift)"))
        XCTAssertFalse(found.swiftLanguageModes.contains { $0.contains(".build") })
        XCTAssertTrue(found.appIdentifiers.isEmpty, "build output is not a source of truth")
    }

    func testPbxprojSettingsAreRead() throws {
        let found = try facts([
            "App.xcodeproj/project.pbxproj": """
            SWIFT_VERSION = 6.0;
            SWIFT_STRICT_CONCURRENCY = complete;
            SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
            PRODUCT_BUNDLE_IDENTIFIER = com.example.app;
            PRODUCT_BUNDLE_IDENTIFIER = com.example.appUITests;
            """
        ])
        XCTAssertEqual(found.swiftLanguageModes, ["6.0 (App.xcodeproj/project.pbxproj)"])
        XCTAssertEqual(found.concurrencySettings, [
            "SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (App.xcodeproj/project.pbxproj)",
            "SWIFT_STRICT_CONCURRENCY = complete (App.xcodeproj/project.pbxproj)"
        ])
        XCTAssertEqual(found.appIdentifiers, ["com.example.app"])
    }

    // MARK: - Through `amoo init --save`

    func testSavedProfileCarriesTheLaunchConfigurationAndEvidence() throws {
        let root = try repository([
            "UITests/SelectionUITests.swift": Self.selectionTests,
            "UITests/DynamicTypeUITests.swift": Self.dynamicTypeTests,
            "UITests/SampleUITestCase.swift": Self.support,
            "App.xcodeproj/project.xcproj": Self.project
        ])
        try saveInitTestProfile(at: root)
        let profile = try String(contentsOf: root.appendingPathComponent("amoo.md"), encoding: .utf8)
        XCTAssertTrue(profile.contains("## Launch configuration (observed)"), profile)
        XCTAssertTrue(profile.contains("## Concurrency"), profile)
        XCTAssertTrue(profile.contains("## App identifiers"), profile)
        XCTAssertTrue(profile.contains("UITests/SelectionUITests.swift:5"), profile)

        let context = try RepositoryTestProfile.load(root.appendingPathComponent("amoo.md"))
        XCTAssertEqual(
            context.launchArguments,
            [
                "-AppleLanguages",
                "(en)",
                "-AppleLocale",
                "en_US",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryL"
            ]
        )
        XCTAssertTrue(context.launchEnvironment.isEmpty)
    }

    func testAContextWithoutLaunchFieldsKeepsItsSerializedForm() throws {
        let plain = try JSONEncoder().encode(StudioTestContext(baseClass: "Base"))
        let text = try XCTUnwrap(String(bytes: plain, encoding: .utf8))
        XCTAssertFalse(text.contains("launchArguments"), text)
        XCTAssertFalse(text.contains("launchEnvironment"), text)

        let seeded = try JSONEncoder().encode(StudioTestContext(launchArguments: ["-AppleLocale", "en_US"]))
        let decoded = try JSONDecoder().decode(StudioTestContext.self, from: seeded)
        XCTAssertEqual(decoded.launchArguments, ["-AppleLocale", "en_US"])
    }
}
