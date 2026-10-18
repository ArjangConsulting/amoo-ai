@testable import CLI
import XCTest

final class PromptingTests: XCTestCase {
    func testSingleDigitChoiceRetriesInvalidInput() {
        var answers = ["x", "0", "4", "2"]
        let prompter = StdioPrompter(readAnswer: { immediate in
            XCTAssertTrue(immediate)
            return answers.removeFirst()
        })
        XCTAssertEqual(prompter.choose("Platform", options: ["iOS", "Android", "Both"], default: 0), 1)
        XCTAssertTrue(answers.isEmpty)
    }

    func testMultiDigitChoiceReadsWholeLine() {
        let prompter = StdioPrompter(readAnswer: { immediate in
            XCTAssertFalse(immediate)
            return "10"
        })
        XCTAssertEqual(prompter.choose("App", options: Array(repeating: "App", count: 10), default: 0), 9)
    }

    func testConfirmationRetriesAndAcceptsUppercaseKey() {
        var answers = ["x", "N"]
        let prompter = StdioPrompter(readAnswer: { immediate in
            XCTAssertTrue(immediate)
            return answers.removeFirst()
        })
        XCTAssertEqual(prompter.confirm("Continue?", default: true), false)
        XCTAssertTrue(answers.isEmpty)
    }

    func testEnterKeepsDefaultAndEOFCancels() {
        let enter = StdioPrompter(readAnswer: { _ in "" })
        XCTAssertEqual(enter.confirm("Continue?", default: false), false)
        XCTAssertEqual(enter.choose("App", options: ["A", "B"], default: 1), 1)
        let eof = StdioPrompter(readAnswer: { _ in nil })
        XCTAssertNil(eof.confirm("Continue?", default: true))
        XCTAssertNil(eof.choose("App", options: ["A"], default: 0))
    }

    func testTextAndMultipleSelectionsReadWholeLines() {
        let prompter = StdioPrompter(readAnswer: { immediate in
            XCTAssertFalse(immediate)
            return "1,3"
        })
        XCTAssertEqual(prompter.ask("Path", default: nil), "1,3")
        XCTAssertEqual(prompter.chooseMany("Devices", options: ["A", "B", "C"], defaults: []), [0, 2])
    }

    func testKeyboardMultipleSelectionAndOrdering() {
        var keys: [Int32] = [1002, 32, 1002, 32, 13]
        let prompter = StdioPrompter(selectionEnabled: true, readSelectionKey: { keys.removeFirst() })
        XCTAssertEqual(prompter.chooseMany("Devices", options: ["A", "B", "C"], defaults: [0]), [0, 1, 2])
    }

    func testKeyboardSingleSelectionWrapsAndCancels() {
        var keys: [Int32] = [1001, 13, -1]
        let prompter = StdioPrompter(selectionEnabled: true, readSelectionKey: { keys.removeFirst() })
        XCTAssertEqual(prompter.choose("Platform", options: ["A", "B"], default: 0), 1)
        XCTAssertNil(prompter.chooseMany("Devices", options: ["A"], defaults: [0]))
    }

    func testKeyboardRequiresSelectionAndSupportsAllToggle() {
        var keys: [Int32] = [32, 13, 97, 97, 13, 1002, 32, 13]
        let prompter = StdioPrompter(selectionEnabled: true, readSelectionKey: { keys.removeFirst() })
        XCTAssertEqual(prompter.chooseMany("Devices", options: ["A", "B"], defaults: [0]), [1])
        XCTAssertTrue(keys.isEmpty)
    }
}
