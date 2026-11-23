import AmooCore
import AmooTools
@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import TestCommons
import XCTest

/// `generate plan --from-flow` keeps a flow extension's steps, and `generate test` asks the
/// extension (`emit`) for their code, its setup and its teardown.
final class GenerateExtensionCodeTests: XCTestCase {
    private final class FakeEmitter: FlowExtensionEmitting, @unchecked Sendable {
        private(set) var requests: [(prefix: String, request: [String: Value])] = []
        var refuse: Set<String> = []

        func emit(prefix: String, request: Value) throws -> Value {
            let fields = request.objectValue ?? [:]
            requests.append((prefix, fields))
            let phase = fields["phase"]?.stringValue ?? ""
            let tool = fields["step"]?.objectValue?["tool"]?.stringValue
            if let tool, refuse.contains(tool) {
                return .object(["protocol": .int(1), "ok": .bool(false), "message": .string("no \(tool) here")])
            }
            switch phase {
            case "setup":
                return .object([
                    "protocol": .int(1), "imports": .array([.string("MockKit")]),
                    "members": .array([.string("private let mock = MockClient()")]),
                    "lines": .array([.string("try mock.openSession()")]), "requires": .array([.string("throws")])
                ])
            case "teardown":
                return .object(["protocol": .int(1), "lines": .array([.string("try mock.closeSession()")])])
            default:
                let arguments = fields["step"]?.objectValue?["arguments"] ?? .null
                return .object([
                    "protocol": .int(1),
                    "lines": .array([.string("try mock.\(tool ?? "?")(\(arguments.jsonText))")])
                ])
            }
        }
    }

    private var emitters: StudioCodeEmitters {
        var result = StudioCodeEmitters(ios: XCUITestEmitter(), android: EspressoEmitter())
        result.register(ComposeEspressoEmitter(), for: .init(platform: .android, toolkit: .compose))
        return result
    }

    private func writeFlow(_ json: String) throws -> String {
        let url = try makeScratchDirectory().url.appending(path: "check.amoo.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func plan(fromFlow json: String) throws -> String {
        let flowPath = try writeFlow(json)
        let out = try makeScratchDirectory().url
        let result = try runGeneratePlanCommand(options: GeneratePlanOptions(
            flowPath: flowPath,
            outputDirectory: out.path
        ))
        XCTAssertEqual(result.exitCode, 0, result.output)
        return out.appending(path: "plan.json").path
    }

    private let flow = """
    { "platform": "ios", "vars": { "user": "uid-7" }, "extensions": ["flags"], "steps": [
      { "tool": "device_launch_app", "arguments": { "app_id": "com.example.app" } },
      { "tool": "moq.select_variant", "arguments": { "endpoint": "GET /v1/me", "variant": "error" } },
      { "tool": "tap_element", "arguments": { "id": "profile.refresh" } },
      { "tool": "moq.assert_request", "arguments": { "times": 1, "claims": { "sub": "${user}" } } } ] }
    """

    func testAPlanKeepsExtensionStepsWithTheirJSONArgumentsAndDeclaredExtensions() throws {
        let path = try plan(fromFlow: flow)
        let test = try JSONDecoder().decode(StudioAuthoredTest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let operations = try XCTUnwrap(test.compiledPlan?.toolOperations)

        XCTAssertEqual(operations.map(\.tool), ["moq.select_variant", "tap_element", "moq.assert_request"])
        let json = try XCTUnwrap(operations[2].arguments[StudioExtensionCode.argumentsJSONArgument])
        XCTAssertEqual(
            try JSONDecoder().decode(Value.self, from: Data(json.utf8)),
            .object(["times": .int(1), "claims": .object(["sub": .string("uid-7")])])
        )
        XCTAssertEqual(test.compiledPlan?.extensionPrefixes, ["flags", "moq"])
        XCTAssertTrue(test.compiledPlan?.excludedWarnings.isEmpty ?? false)
    }

    func testGenerateAsksEachExtensionForSetupStepsAndTeardown() throws {
        let emitter = FakeEmitter()
        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: plan(fromFlow: flow), outputDirectory: nil),
            emitters: emitters,
            extensionEmitter: emitter
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        let phases = emitter.requests.map { "\($0.prefix):\($0.request["phase"]?.stringValue ?? "")" }
        XCTAssertEqual(phases, ["flags:setup", "flags:teardown", "moq:setup", "moq:teardown", "moq:step", "moq:step"])
        XCTAssertEqual(emitter.requests[0].request["framework"], .string("xcuitest"))
        XCTAssertEqual(emitter.requests[4].request["step"]?.objectValue?["tool"], .string("select_variant"))
        let source = result.output
        XCTAssertTrue(source.contains("import MockKit"), source)
        XCTAssertTrue(source.contains("    private let mock = MockClient()"), source)
        let setUp = try XCTUnwrap(source.range(of: "        try mock.openSession()"))
        let launch = try XCTUnwrap(source.range(of: "        app.launch()"))
        XCTAssertLessThan(setUp.lowerBound, launch.lowerBound, "setup runs before the launch")
        XCTAssertTrue(source.contains("        try mock.closeSession()"), source)
        let variant = try XCTUnwrap(source
            .range(of: #"try mock.select_variant({"endpoint":"GET /v1/me","variant":"error"})"#))
        let tap = try XCTUnwrap(source.range(of: "profile.refresh"))
        XCTAssertLessThan(variant.lowerBound, tap.lowerBound, "step code keeps its place in the flow")
        XCTAssertTrue(source.contains(#"try mock.assert_request({"claims":{"sub":"uid-7"},"times":1})"#), source)
    }

    func testAStepTheExtensionCannotExpressRefusesTheTestUnlessIncompleteIsAllowed() throws {
        let emitter = FakeEmitter()
        emitter.refuse = ["assert_request"]
        let planPath = try plan(fromFlow: flow)

        let refused = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: planPath, outputDirectory: nil),
            emitters: emitters,
            extensionEmitter: emitter
        )
        XCTAssertEqual(refused.exitCode, 65)
        XCTAssertTrue(refused.output.contains("moq.assert_request: no assert_request here"), refused.output)
        XCTAssertFalse(refused.output.contains("class "), "must not emit code")

        let allowed = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: planPath, outputDirectory: nil, allowIncomplete: true),
            emitters: emitters,
            extensionEmitter: emitter
        )
        XCTAssertEqual(allowed.exitCode, 0, allowed.output)
        XCTAssertTrue(
            allowed.output.contains(#"XCTFail("moq.assert_request has no xcuitest equivalent")"#),
            allowed.output
        )
    }

    func testAnAndroidComposePlanAsksForComposeAndGetsBeforeAndAfter() throws {
        let emitter = FakeEmitter()
        let path = try plan(fromFlow: flow.replacingOccurrences(
            of: #""platform": "ios""#,
            with: #""platform": "android""#
        ))

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil, uiToolkit: .compose),
            emitters: emitters,
            extensionEmitter: emitter
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(emitter.requests.first?.request["framework"], .string("compose"))
        XCTAssertTrue(
            result.output.contains("    @Before\n    fun setUpFlowExtensions() {\n        try mock.openSession()"),
            result.output
        )
        XCTAssertTrue(result.output.contains("    @After\n    fun tearDownFlowExtensions() {"), result.output)
        XCTAssertTrue(result.output.contains("import org.junit.Before"), result.output)
    }

    func testAPlanWithoutExtensionsNeverAsks() throws {
        let emitter = FakeEmitter()
        let path = try plan(fromFlow: """
        { "platform": "ios", "steps": [ { "tool": "tap_element", "arguments": { "id": "a" } } ] }
        """)

        let result = try runGenerateTestCommand(
            options: GenerateTestOptions(planPath: path, outputDirectory: nil),
            emitters: emitters,
            extensionEmitter: emitter
        )

        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(emitter.requests.isEmpty)
    }
}
