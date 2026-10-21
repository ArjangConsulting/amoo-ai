import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Source maps let Studio highlight the generated lines for a selected step; they must never change
/// the generated code.
final class SourceMappingTests: XCTestCase {
    private func test(
        _ platform: Platform,
        _ operations: [StudioToolOperation],
        warnings: [StudioPlanWarning]? = nil
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In",
            description: "",
            platform: platform,
            steps: [.init(id: "step-0", instruction: "Sign in", expected: "Home")],
            compiledPlan: .init(
                compiler: "session",
                compilerVersion: "1",
                toolOperations: operations,
                warnings: warnings
            )
        )
    }

    private let signIn: [StudioToolOperation] = [
        .init(id: "step-0", tool: "tap_element", arguments: ["id": "login"]),
        .init(id: "step-1", tool: "set_text", arguments: ["id": "email", "value": "person@example.com"]),
        .init(id: "step-2", tool: "assert_visible", arguments: ["id": "home"])
    ]

    func testEveryEmitterMapsEachOperationToItsOwnLinesWithoutChangingOutput() throws {
        let cases: [(any StudioCodeEmitting, Platform)] = [
            (XCUITestEmitter(), .ios),
            (EspressoEmitter(), .android),
            (ComposeEspressoEmitter(), .android)
        ]
        for (emitter, platform) in cases {
            let plan = test(platform, signIn)
            let mapped = try emitter.generateMapped(plan)
            let plain = try emitter.generate(plan)
            let lines = mapped.source.components(separatedBy: "\n")

            XCTAssertEqual(mapped.source, plain.source, "\(type(of: emitter))")
            XCTAssertEqual(mapped.sourceMap.map(\.operationId), ["step-0", "step-1", "step-2"], "\(type(of: emitter))")
            for (entry, marker) in zip(mapped.sourceMap, ["login", "email", "home"]) {
                let span = lines[(entry.startLine - 1) ... (entry.endLine - 1)].joined(separator: "\n")
                XCTAssertTrue(
                    span.contains(marker),
                    "\(type(of: emitter)) step \(entry.operationId) lacks \(marker): \(span)"
                )
            }
            XCTAssertTrue(zip(mapped.sourceMap, mapped.sourceMap.dropFirst()).allSatisfy { $0.endLine < $1.startLine })
        }
    }

    func testLanguageFollowsTheFileExtension() throws {
        XCTAssertEqual(try XCUITestEmitter().generateMapped(test(.ios, signIn)).language, "swift")
        XCTAssertEqual(try EspressoEmitter().generateMapped(test(.android, signIn)).language, "kotlin")
    }

    func testCollapsedWaitsAndInsertedFailuresKeepSpansAccurate() throws {
        let repeated: [StudioToolOperation] = [
            .init(id: "step-0", tool: "tap_element", arguments: ["id": "menu"]),
            .init(id: "step-1", tool: "tap_element", arguments: ["id": "menu"]),
            .init(id: "step-2", tool: "assert_visible", arguments: ["id": "settings"])
        ]
        let warning = StudioPlanWarning(kind: .excluded, actionIndex: 1, toolName: "pinch", reason: "no equivalent")
        let mapped = try XCUITestEmitter().generateMapped(test(.ios, repeated, warnings: [warning]))
        let lines = mapped.source.components(separatedBy: "\n")

        XCTAssertEqual(mapped.sourceMap.count, 3)
        let failLine = try XCTUnwrap(lines.firstIndex { $0.contains("XCTFail(\"Uncompiled required action 1") }) + 1
        XCTAssertFalse(mapped.sourceMap.contains { $0.startLine <= failLine && failLine <= $0.endLine })
        let last = try XCTUnwrap(mapped.sourceMap.last)
        XCTAssertTrue(lines[(last.startLine - 1) ... (last.endLine - 1)].joined().contains("settings"))
    }

    func testTheMapperToleratesReindentationAndInsertions() {
        let source = """
        header
            first()
            inserted()
            second()
            second()
        """
        let entries = StudioSourceMapper.map(
            statements: ["first()", "second()\n\nsecond()"],
            operationIds: ["a", "b"],
            in: source
        )

        XCTAssertEqual(entries, [
            .init(operationIndex: 0, operationId: "a", startLine: 2, endLine: 2),
            .init(operationIndex: 1, operationId: "b", startLine: 4, endLine: 5)
        ])
    }
}
