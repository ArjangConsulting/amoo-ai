import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// The `testContext` path through `XCUITestEmitter`: app-supplied imports, base class, app factory,
/// and explicitly-named helpers.
final class XCUITestContextTests: XCTestCase {
    private func makeTest(operations: [StudioToolOperation]) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In Flow",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Sign in", expected: "Home screen appears")],
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: operations
            )
        )
    }

    func testSharedHelpersCompileWithSwiftSix() throws {
        guard let modulePath = ProcessInfo.processInfo.environment["TESTCOMMONS_XCUI_MODULE_PATH"] else {
            throw XCTSkip("Set TESTCOMMONS_XCUI_MODULE_PATH to the built iOS Simulator module directory")
        }
        let test = makeTest(operations: [.init(id: "tap", tool: "tap_element", arguments: ["id": "submit"])])
        let source = try XCUITestEmitter(useTestCommons: true).generate(test).source
        try CompileVerification.verifySwiftCompiles(source, additionalImportPaths: [modulePath], swiftVersion: 6)
    }

    func testSharedHelpersAreOptIn() throws {
        let test = makeTest(operations: [
            .init(id: "tap", tool: "tap_element", arguments: ["id": "submit"])
        ])
        let standalone = try XCUITestEmitter().generate(test).source
        XCTAssertFalse(standalone.contains("import TestCommonsXCUI"))
        let shared = try XCUITestEmitter(useTestCommons: true).generate(test).source
        XCTAssertTrue(shared.contains("import TestCommonsXCUI"))
        XCTAssertTrue(shared.contains("TestCommonsXCUI.waitForHittability"))
        XCTAssertTrue(shared.contains("TestCommonsXCUI.waitForAbsence"))
        XCTAssertTrue(shared.contains("TestCommonsXCUI.attachDiagnostics"))
        XCTAssertFalse(shared.contains("XCTAttachment(screenshot:"))
    }

    func testXCUITestEmitterUsesExplicitContextHelperAndHarness() throws {
        let context = StudioTestContext(
            imports: ["AppTestSupport"],
            baseClass: "AppUITestCase",
            appFactory: "makeApp()",
            helpers: [
                .init(
                    name: "signIn",
                    callTemplate: "signIn(email: {{email}}, password: {{password}})"
                )
            ]
        )
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Contextual sign in",
            description: "",
            platform: .ios,
            steps: [],
            testContext: context,
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [
                    .init(
                        id: "step-0",
                        tool: "tap_element",
                        arguments: ["email": "user@example.com", "password": "secret"],
                        helper: "signIn"
                    )
                ]
            )
        )

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("import AppTestSupport"))
        XCTAssertTrue(result.source.contains("final class ContextualSignInTest: AppUITestCase"))
        XCTAssertTrue(result.source.contains("private lazy var app = makeApp()"))
        XCTAssertTrue(result.source.contains(#"signIn(email: "user@example.com", password: "secret")"#))
        XCTAssertFalse(result.source.contains("descendants(matching:"))
    }

    func testXCUITestEmitterEmitsHelperLevelImports() throws {
        let context = StudioTestContext(
            imports: ["AppTestSupport"],
            helpers: [
                .init(name: "signIn", callTemplate: "signIn(email: {{email}})", imports: ["SignInKit"])
            ]
        )
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Contextual sign in",
            description: "",
            platform: .ios,
            steps: [],
            testContext: context,
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [
                    .init(
                        id: "step-0",
                        tool: "tap_element",
                        arguments: ["email": "user@example.com"],
                        helper: "signIn"
                    )
                ]
            )
        )

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("import AppTestSupport"))
        XCTAssertTrue(result.source.contains("import SignInKit"))
    }

    private func makeTest(context: StudioTestContext) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Contextual sign in",
            description: "",
            platform: .ios,
            steps: [],
            testContext: context,
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [
                    .init(
                        id: "step-0",
                        tool: "tap_element",
                        arguments: ["id": "sign-in"]
                    )
                ]
            )
        )
    }

    func testXCUITestEmitterAlwaysChainsToSuper() throws {
        let result = try XCUITestEmitter().generate(
            makeTest(context: .init(baseClass: "AppUITestCase"))
        )

        XCTAssertTrue(result.source.contains("try super.setUpWithError()"))
        XCTAssertTrue(result.source.contains("try super.tearDownWithError()"))
    }

    func testXCUITestEmitterStillLaunchesWhenABaseClassIsNamedButDoesNotLaunch() throws {
        // Naming a base class is not a claim that it launches the app. A sample app's checked-in
        // context names `XCTestCase` explicitly and relies on the emitter to launch; inferring
        // otherwise would run every generated test against an app that never started.
        let context = StudioTestContext(
            baseClass: "XCTestCase",
            appFactory: "SampleAppLauncher.withMockServer()"
        )

        let result = try XCUITestEmitter().generate(makeTest(context: context))

        XCTAssertTrue(result.source.contains("app.launch()"))
    }

    func testXCUITestEmitterOmitsLaunchOnlyWhenTheHarnessDeclaresIt() throws {
        let context = StudioTestContext(baseClass: "AppUITestCase", harnessLaunchesApp: true)

        let result = try XCUITestEmitter().generate(makeTest(context: context))

        XCTAssertFalse(result.source.contains("app.launch()"))
    }

    func testTestContextWithoutHarnessLaunchesAppKeyStillDecodes() throws {
        let json = Data(#"{"imports":[],"baseClass":"XCTestCase","helpers":[]}"#.utf8)

        let context = try JSONDecoder().decode(StudioTestContext.self, from: json)

        XCTAssertFalse(context.harnessLaunchesApp)
    }

    /// The exact schema documented in `docs/test-context.md` — including `idLookupTemplate: null`
    /// and empty `helpers` / `selectorExpressions` — decodes and produces the documented scaffold:
    /// the support module is imported, the base class is subclassed, `harnessLaunchesApp` suppresses
    /// the emitter's own `app.launch()`, and both overrides still chain to `super`.
    func testDocumentedXCUITestContextSchemaGeneratesTheExpectedScaffold() throws {
        let json = Data(
            """
            {
              "imports": ["MyUITestSupport"],
              "baseClass": "MyAppUITestCase",
              "appFactory": "makeTestApplication()",
              "harnessLaunchesApp": true,
              "helpers": [],
              "selectorExpressions": {},
              "idLookupTemplate": null
            }
            """.utf8
        )
        let context = try JSONDecoder().decode(StudioTestContext.self, from: json)

        let result = try XCUITestEmitter().generate(makeTest(context: context))

        XCTAssertTrue(result.source.contains("import MyUITestSupport"))
        XCTAssertTrue(result.source.contains("final class ContextualSignInTest: MyAppUITestCase"))
        XCTAssertTrue(result.source.contains("private lazy var app = makeTestApplication()"))
        // harnessLaunchesApp: true -> no duplicate launch.
        XCTAssertFalse(result.source.contains("app.launch()"))
        // super chaining preserved.
        XCTAssertTrue(result.source.contains("try super.setUpWithError()"))
        XCTAssertTrue(result.source.contains("try super.tearDownWithError()"))
    }

    func testXCUITestEmitterRejectsAnUndeclaredContextHelper() {
        let test = makeTest(operations: [.init(id: "step-0", tool: "tap_element", helper: "signIn")])

        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, .unknownTestHelper("signIn"))
        }
    }
}

/// A swipe on an element an earlier step already bound reuses that variable instead of looking the
/// element up again, and a lookup goes through the context's selector expressions like any other step.
final class XCUITestSwipeLookupTests: XCTestCase {
    private func source(_ operations: [StudioToolOperation], context: StudioTestContext? = nil) throws -> String {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Swipe Flow",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Swipe", expected: "Swiped")],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
        return try XCUITestEmitter().generate(test).source
    }

    func testASwipeOnAnAlreadyBoundElementReusesItsVariable() throws {
        let code = try source([
            .init(id: "1", tool: "assert_visible", arguments: ["id": "day.screen"]),
            .init(id: "2", tool: "swipe_in_direction", arguments: ["element_id": "day.screen", "direction": "up"])
        ])
        XCTAssertEqual(code.components(separatedBy: #"["day.screen"]"#).count - 1, 1, "looked up once:\n\(code)")
        XCTAssertTrue(code.contains(".swipeUp()"), code)
    }

    func testASwipeTargetUsesTheContextSelectorExpression() throws {
        let context = StudioTestContext(selectorExpressions: ["day.screen": "JotUIAutomationID.DayDetail.screen"])
        let code = try source([
            .init(id: "1", tool: "swipe_in_direction", arguments: ["element_id": "day.screen", "direction": "up"])
        ], context: context)
        XCTAssertTrue(code.contains("JotUIAutomationID.DayDetail.screen"), code)
        XCTAssertFalse(code.contains(#"["day.screen"]"#), "no raw id lookup:\n\(code)")
    }
}

/// `requiredIdiom` makes an iPhone recording skip itself on an iPad (and the reverse) instead of
/// tapping controls that are not there; before it, every export needed a hand-added guard and import.
final class XCUITestIdiomGuardTests: XCTestCase {
    private func source(idiom: StudioTestContext.Idiom?) throws -> String {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Idiom Flow",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-1", instruction: "Tap", expected: "Tapped")],
            testContext: idiom.map { StudioTestContext(requiredIdiom: $0) },
            compiledPlan: .init(
                compiler: "ai",
                compilerVersion: "1",
                toolOperations: [.init(id: "1", tool: "tap_element", arguments: ["id": "go"])]
            )
        )
        return try XCUITestEmitter().generate(test).source
    }

    func testAPhoneRecordingSkipsOnAPadBeforeLaunching() throws {
        let code = try source(idiom: .phone)
        XCTAssertTrue(code.contains("import UIKit"), code)
        let skip = try XCTUnwrap(code.range(of: "UIDevice.current.userInterfaceIdiom == .phone"), code)
        let launch = try XCTUnwrap(code.range(of: "app.launch()"), code)
        XCTAssertLessThan(skip.lowerBound, launch.lowerBound, "the guard runs before the launch")
    }

    func testAPadRecordingGuardsOnPad() throws {
        let code = try source(idiom: .pad)
        XCTAssertTrue(code.contains("== .pad"), code)
        XCTAssertTrue(code.contains("Recorded for iPad"), code)
    }

    func testNoIdiomMeansNoGuardAndNoUIKit() throws {
        let code = try source(idiom: nil)
        XCTAssertFalse(code.contains("UIKit"), code)
        XCTAssertFalse(code.contains("XCTSkipUnless"), code)
    }

    func testContextFilesDecodeTheIdiomAndRejectUnknownOnes() throws {
        let ok = try JSONDecoder().decode(StudioTestContext.self, from: Data(#"{"requiredIdiom":"pad"}"#.utf8))
        XCTAssertEqual(ok.requiredIdiom, .pad)
        XCTAssertThrowsError(try JSONDecoder().decode(
            StudioTestContext.self,
            from: Data(#"{"requiredIdiom":"tv"}"#.utf8)
        ))
    }
}
