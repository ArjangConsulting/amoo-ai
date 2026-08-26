import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Guards the single-vocabulary invariant that `StudioTool` exists to enforce.
///
/// The exhaustive switches in each emitter already make a missing tool a *compile* error. These
/// tests cover what the compiler cannot: that every tool is also reachable at run time with a
/// plausible argument set, and that the allow-list and prompt cannot drift from the enum.
final class StudioToolCoverageTests: XCTestCase {
    /// Minimal arguments that should satisfy every emitter for the given tool.
    private func arguments(for tool: StudioTool) -> [String: String] {
        switch tool {
        case .tapElement, .assertVisible, .assertNotVisible, .assertEnabled, .waitForElement:
            ["id": "submit"]
        case .setText:
            ["id": "field", "value": "hello"]
        case .typeText:
            ["text": "hello"]
        case .swipeInDirection, .scroll:
            ["direction": "down"]
        case .assertText:
            ["id": "greeting", "value": "hi"]
        case .takeScreenshot, .pressBack:
            [:]
        }
    }

    private func makeTest(_ tool: StudioTool, platform: Platform) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Coverage",
            description: "",
            platform: platform,
            steps: [],
            compiledPlan: .init(
                compiler: "test",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: tool.rawValue, arguments: arguments(for: tool))]
            )
        )
    }

    func testEveryEmitterHandlesEveryStudioTool() throws {
        for tool in StudioTool.allCases {
            XCTAssertNoThrow(
                try XCUITestEmitter().generate(makeTest(tool, platform: .ios)),
                "XCUITestEmitter cannot emit \(tool.rawValue)"
            )
            XCTAssertNoThrow(
                try EspressoEmitter().generate(makeTest(tool, platform: .android)),
                "EspressoEmitter cannot emit \(tool.rawValue)"
            )
            XCTAssertNoThrow(
                try ComposeEspressoEmitter().generate(makeTest(tool, platform: .android)),
                "ComposeEspressoEmitter cannot emit \(tool.rawValue)"
            )
        }
    }

    func testUnknownToolIsRejectedRatherThanEmittedBlank() {
        let test = StudioAuthoredTest(
            formatVersion: 1,
            name: "Unknown",
            description: "",
            platform: .ios,
            steps: [],
            compiledPlan: .init(
                compiler: "test",
                compilerVersion: "1",
                toolOperations: [.init(id: "op-1", tool: "teleport", arguments: [:])]
            )
        )

        XCTAssertThrowsError(try XCUITestEmitter().generate(test)) {
            XCTAssertEqual($0 as? TestCodeGeneratorError, .unsupportedTool("teleport"))
        }
    }

    func testAllNamesMatchTheRawValues() {
        XCTAssertEqual(Set(StudioTool.allNames), Set(StudioTool.allCases.map(\.rawValue)))
        // Spot-check the two that shipped missing from a site and caused real bugs.
        XCTAssertTrue(StudioTool.allNames.contains("assert_enabled"))
        XCTAssertTrue(StudioTool.allNames.contains("scroll"))
    }
}
