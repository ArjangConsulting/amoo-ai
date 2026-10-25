// swiftlint:disable multiline_arguments
import AmooCore
import MCP
@testable import MCPServer
import XCTest

final class NativeStateAssertionTests: XCTestCase {
    private func assertState(
        _ tool: String, semantics: ElementSemantics?, arguments: [String: String] = [:]
    ) async -> ToolResult {
        let driver = NavigationMockDriver(elements: [ElementInfo(
            id: "control", label: "Control", value: "Editable text", isSelected: true, semantics: semantics
        )])
        return await DriverToolExecutor(driver: driver).execute(
            toolName: tool, arguments: ["id": "control", "timeout_ms": "20"].merging(arguments) { _, new in new }
        )
    }

    func testCheckedFalseUsesActualCheckablePropertyIndependentlyOfSelectedTrue() async {
        let result = await assertState(
            "assert_checked",
            semantics: .init(isCheckable: true, isChecked: false),
            arguments: ["expected": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observed"], .bool(false))
    }

    func testUnavailableAndInapplicableCheckedPropertyAreUnsupportedEvenForFalse() async {
        for semantics in [nil, ElementSemantics(isCheckable: false, isChecked: false)] {
            let result = await assertState("assert_checked", semantics: semantics, arguments: ["expected": "false"])
            XCTAssertTrue(result.isError)
            XCTAssertEqual(result.structuredContent?.objectValue?["failure_kind"], .string("unsupported_property"))
        }
    }

    func testStateDescriptionReadsNativePropertyWithoutUsingEditableValue() async {
        let result = await assertState(
            "assert_state_description",
            semantics: .init(stateDescription: "Copied"),
            arguments: ["expected": "Copied"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["observed"], .string("Copied"))
    }

    func testEmptyDescriptionIsKnownWhileMissingDescriptionRemainsUnsupported() async {
        let known = await assertState(
            "assert_state_description",
            semantics: .init(stateDescription: ""),
            arguments: ["expected": ""]
        )
        XCTAssertFalse(known.isError, known.content)
        let missing = await assertState("assert_state_description", semantics: .init(), arguments: ["expected": ""])
        XCTAssertEqual(missing.structuredContent?.objectValue?["failure_kind"], .string("unsupported_property"))
    }

    func testMismatchRetainsLastCheckedStateAndInvalidBooleanNeverDefaults() async {
        let result = await assertState("assert_checked", semantics: .init(isCheckable: true, isChecked: false))
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["observed"], .bool(false))
        XCTAssertEqual(result.structuredContent?.objectValue?["failure_kind"], .string("assertion_mismatch"))
        let invalid = await assertState(
            "assert_checked",
            semantics: .init(isCheckable: true, isChecked: true),
            arguments: ["expected": ""]
        )
        XCTAssertTrue(invalid.isError)
    }

    func testTalkBackSpeechIsNotPersistedWithoutOptIn() async throws {
        let report = AccessibilityInspection(
            status: "observed", provider: "androidTalkBack", utterances: ["private utterance"],
            provenance: ["speech_expectations_json": "private expectation"]
        )
        let result = try ToolResult(content: "Observed", structuredContent: Value(report))
        let executor = DriverToolExecutor(driver: MockDriver())
        let evidence = await executor.diagnosticEvidence(toolName: "test_talkback", arguments: [:], result: result)
        let encoded = try JSONEncoder().encode(evidence)
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("private utterance"))
        XCTAssertFalse(text.contains("private expectation"))
        XCTAssertTrue(text.contains("speech not retained"))
    }
}

// swiftlint:enable multiline_arguments
