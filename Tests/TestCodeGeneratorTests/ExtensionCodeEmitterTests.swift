import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Where each emitter puts code that flow extensions supplied, and that the result compiles.
final class ExtensionCodeEmitterTests: XCTestCase {
    private func makeTest(platform: Platform, code: StudioExtensionCode, step: [String]) -> StudioAuthoredTest {
        var test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Mocked Refresh",
            description: "",
            platform: platform,
            steps: [.init(id: "step-1", instruction: "Refresh", expected: "Refreshed")],
            compiledPlan: .init(compiler: "session-compiler", compilerVersion: "1", toolOperations: [
                .init(id: "op-1", tool: StudioExtensionCode.operationTool, arguments: [
                    StudioExtensionCode.codeArgument: step.joined(separator: "\n")
                ]),
                .init(id: "op-2", tool: "tap_element", arguments: ["id": "refresh"])
            ])
        )
        test.extensionCode = code
        return test
    }

    private let swiftCode = StudioExtensionCode(
        imports: ["Foundation"],
        members: ["private var calls: [String] = []"],
        setUp: [#"calls.append("setup")"#],
        tearDown: [#"calls.append("teardown")"#],
        requiresThrows: true
    )

    private let kotlinCode = StudioExtensionCode(
        imports: ["java.util.concurrent.atomic.AtomicInteger"],
        members: ["private val calls = AtomicInteger(0)"],
        setUp: ["calls.incrementAndGet()"],
        tearDown: ["calls.decrementAndGet()"]
    )

    func testXCUITestPlacesSetupBeforeLaunchTeardownAfterAttachmentsAndStepsInOrder() throws {
        let source = try XCUITestEmitter().generate(
            makeTest(platform: .ios, code: swiftCode, step: [#"calls.append("step")"#])
        ).source

        XCTAssertTrue(source.contains("import Foundation"), source)
        XCTAssertTrue(source.contains("    private var calls: [String] = []\n    private lazy var app"), source)
        let setUp = try XCTUnwrap(source.range(of: #"        calls.append("setup")"#))
        let launch = try XCTUnwrap(source.range(of: "        app.launch()"))
        XCTAssertLessThan(setUp.lowerBound, launch.lowerBound)
        let attachments = try XCTUnwrap(source.range(of: "add(hierarchy)"))
        let tearDown = try XCTUnwrap(source.range(of: #"        calls.append("teardown")"#))
        XCTAssertLessThan(attachments.lowerBound, tearDown.lowerBound)
        let step = try XCTUnwrap(source.range(of: #"        calls.append("step")"#))
        let tap = try XCTUnwrap(source.range(of: "refresh"))
        XCTAssertLessThan(step.lowerBound, tap.lowerBound)
        XCTAssertTrue(source.contains("func testMockedRefresh() throws {"), source)
        try CompileVerification.verifySwiftCompiles(source)
    }

    func testXCUITestMakesTheTestAsyncWhenStepCodeAwaits() throws {
        let code = StudioExtensionCode(
            members: ["private func settle() async throws {}"],
            requiresThrows: true,
            requiresAsync: true
        )
        let source = try XCUITestEmitter().generate(
            makeTest(platform: .ios, code: code, step: ["try await settle()"])
        ).source

        XCTAssertTrue(source.contains("func testMockedRefresh() async throws {"), source)
        try CompileVerification.verifySwiftCompiles(source)
    }

    func testXCUITestRefusesAsyncSetupInASynchronousLifecycle() {
        let code = StudioExtensionCode(setUp: ["try await open()"], requiresAsync: true)

        XCTAssertThrowsError(try XCUITestEmitter().generate(makeTest(platform: .ios, code: code, step: []))) { error in
            guard case .unsupportedOnTarget = error as? TestCodeGeneratorError else {
                return XCTFail("\(error)")
            }
        }
    }

    func testEspressoGetsBeforeAndAfterAndCompiles() throws {
        let source = try EspressoEmitter().generate(
            makeTest(platform: .android, code: kotlinCode, step: ["calls.incrementAndGet()"])
        ).source

        XCTAssertTrue(source.contains("import java.util.concurrent.atomic.AtomicInteger"), source)
        XCTAssertTrue(
            source.contains("    @Before\n    fun setUpFlowExtensions() {\n        calls.incrementAndGet()"),
            source
        )
        XCTAssertTrue(
            source.contains("    @After\n    fun tearDownFlowExtensions() {\n        calls.decrementAndGet()"),
            source
        )
        try CompileVerification.verifyKotlinCompiles(source)
    }

    func testComposeGetsBeforeAndAfterAndCompiles() throws {
        let source = try ComposeEspressoEmitter().generate(
            makeTest(platform: .android, code: kotlinCode, step: ["calls.incrementAndGet()"])
        ).source

        XCTAssertTrue(source.contains("    private val calls = AtomicInteger(0)"), source)
        XCTAssertTrue(source.contains("import org.junit.After"), source)
        try CompileVerification.verifyKotlinCompiles(source)
    }

    func testKotlinRefusesAsyncCode() {
        let code = StudioExtensionCode(requiresAsync: true)

        XCTAssertThrowsError(try EspressoEmitter().generate(makeTest(platform: .android, code: code, step: ["x()"])))
        XCTAssertThrowsError(try ComposeEspressoEmitter().generate(makeTest(
            platform: .android,
            code: code,
            step: ["x()"]
        )))
    }
}
