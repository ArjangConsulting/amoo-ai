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
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: operations)
        )
    }

    func testXCUITestEmitterUsesExplicitContextHelperAndHarness() throws {
        let context = StudioTestContext(
            imports: ["AppTestSupport"],
            baseClass: "AppUITestCase",
            appFactory: "makeApp()",
            helpers: [.init(
                name: "signIn",
                callTemplate: "signIn(email: {{email}}, password: {{password}})"
            )]
        )
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Contextual sign in",
            description: "",
            platform: .ios,
            steps: [],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: [.init(
                id: "step-0",
                tool: "tap_element",
                arguments: ["email": "user@example.com", "password": "secret"],
                helper: "signIn"
            )])
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
            helpers: [.init(name: "signIn", callTemplate: "signIn(email: {{email}})", imports: ["SignInKit"])]
        )
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Contextual sign in",
            description: "",
            platform: .ios,
            steps: [],
            testContext: context,
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: [.init(
                id: "step-0",
                tool: "tap_element",
                arguments: ["email": "user@example.com"],
                helper: "signIn"
            )])
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
            compiledPlan: .init(compiler: "ai", compilerVersion: "1", toolOperations: [.init(
                id: "step-0",
                tool: "tap_element",
                arguments: ["id": "sign-in"]
            )])
        )
    }

    func testXCUITestEmitterAlwaysChainsToSuper() throws {
        let result = try XCUITestEmitter().generate(makeTest(context: .init(baseClass: "AppUITestCase")))

        XCTAssertTrue(result.source.contains("try super.setUpWithError()"))
        XCTAssertTrue(result.source.contains("try super.tearDownWithError()"))
    }

    func testXCUITestEmitterStillLaunchesWhenABaseClassIsNamedButDoesNotLaunch() throws {
        // Naming a base class is not a claim that it launches the app. SampleApp's checked-in
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

    func testXCUITestEmitterRejectsAnUndeclaredContextHelper() {
        let test = makeTest(operations: [.init(id: "step-0", tool: "tap_element", helper: "signIn")])

        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, .unknownTestHelper("signIn"))
        }
    }
}
