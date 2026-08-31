import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Focused coverage for semantic-first local-variable naming: label/role priority, opaque-id
/// rejection, punctuation/emoji/localization handling, collisions, and determinism.
final class ElementVariableNamingTests: XCTestCase {
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

    // MARK: - Semantic variable naming

    func testElementVariableBaseNamesFromLabelAndInferredRoleNotOpaqueID() {
        // accessibility ID with a trailing UUID + a real label → semantic name, never the UUID.
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(
                id: "app.task_list.row.a40fb286-e7ca-42ad-9163-5a316ba856bd",
                label: "Cigarettes"
            ),
            "cigarettesHabitRow"
        )
    }

    func testElementVariableBaseWorkedExamples() {
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(id: "app.tab.tasks", label: "Habits"),
            "habitsTab"
        )
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(id: "app.task_list.create_button", label: "Create Habit"),
            "createHabitButton"
        )
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(label: "Delete", elementType: "button"),
            "deleteButton"
        )
        // No label: keep the namespaced ID's meaningful suffix + role (unchanged behaviour).
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(id: "sample.home.feed.sectionTitle.most_loved"),
            "mostLovedSectionTitle"
        )
    }

    func testObservedElementTypeSuppliesRoleWhenIdentifierDoesNot() {
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(
                id: "trash",
                label: "Delete",
                elementType: "button"
            ),
            "deleteButton"
        )
    }

    func testElementVariableBaseTreatsUUIDsHashesAndNumericIDsAsNonSemantic() {
        XCTAssertTrue(TestIdentifierNaming.isOpaqueToken("a40fb286-e7ca-42ad-9163-5a316ba856bd"))
        XCTAssertTrue(TestIdentifierNaming.isOpaqueToken("9f8c2b1a7d6e5f4c3b2a1908")) // 24 hex chars
        XCTAssertTrue(TestIdentifierNaming.isOpaqueToken("1048576")) // numeric record id
        XCTAssertTrue(TestIdentifierNaming.isOpaqueToken("aGVsbG8gd29ybGQgb3BhcXVl")) // long mixed blob
        XCTAssertFalse(TestIdentifierNaming.isOpaqueToken("create_button"))
        XCTAssertFalse(TestIdentifierNaming.isOpaqueToken("habits"))

        // When the trailing segment is opaque, naming falls back to the role only — never the hash.
        let base = TestIdentifierNaming.elementVariableBase(id: "app.task_list.row.a40fb286e7ca42ad")
        XCTAssertFalse(base.lowercased().contains("a40fb286"))
        XCTAssertEqual(base, "habitCatalogRow")
    }

    func testLongDescriptiveIdentifierSegmentIsNotMistakenForAnOpaqueBlob() {
        // 31 chars, has a digit, no separator — but it contains real words, so it is a name.
        XCTAssertFalse(TestIdentifierNaming.isOpaqueToken("recommendationsCarouselV2Section"))
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(id: "home.feed.recommendationsCarouselV2Section"),
            "recommendationsCarouselV2Section"
        )
    }

    func testElementVariableBaseStripsPunctuationEmojiAndCompositeLabelProse() {
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(label: "🚬 Cigarettes", elementType: "cell"),
            "cigarettesCell"
        )
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(label: "Don't Panic!", elementType: "button"),
            "dontPanicButton"
        )
        // Combined SwiftUI label: only the first clause names the element.
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(
                id: "app.task_list.row.a40fb286-e7ca-42ad-9163-5a316ba856bd",
                label: "🚬 Cigarettes, Track how many cigarettes you smoked today., Unit"
            ),
            "cigarettesHabitRow"
        )
    }

    func testElementVariableBaseKeepsLocalizedLetters() {
        // A non-English label keeps its letters rather than collapsing to `element`.
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(label: "Café", elementType: "button"),
            "caféButton"
        )
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(label: "Recevoir le code", elementType: "button"),
            "recevoirLeCodeButton"
        )
    }

    func testElementVariableBaseFallsBackToElementWhenNothingSemantic() {
        XCTAssertEqual(TestIdentifierNaming.elementVariableBase(), "element")
        XCTAssertEqual(TestIdentifierNaming.elementVariableBase(label: "🔥🔥"), "element")
        XCTAssertEqual(
            TestIdentifierNaming.elementVariableBase(
                id: "session.a40fb286-e7ca-42ad-9163-5a316ba856bd.9f8c2b1a7d6e5f4c3b2a1908"
            ),
            "element"
        )
    }

    func testElementVariableBaseIsDeterministicAcrossRepeatedCalls() {
        let inputs = (
            id: "app.task_list.row.a40fb286-e7ca-42ad-9163-5a316ba856bd",
            label: "🚬 Cigarettes, Track how many cigarettes you smoked today."
        )
        let names = (0 ..< 25).map { _ in
            TestIdentifierNaming.elementVariableBase(id: inputs.id, label: inputs.label)
        }
        XCTAssertEqual(Set(names), ["cigarettesHabitRow"])
    }

    func testXCUITestEmitterNamesElementScopedSwipeFromResolvedLabelNotUUID() throws {
        let test = makeTest(operations: [.init(
            id: "step-3",
            tool: "swipe_in_direction",
            arguments: [
                "direction": "left",
                "element_id": "app.task_list.row.a40fb286-e7ca-42ad-9163-5a316ba856bd",
                "element_label": "🚬 Cigarettes, Track how many cigarettes you smoked today., Unit"
            ]
        )])

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("let cigarettesHabitRow = app.descendants(matching: .any)["))
        XCTAssertTrue(result.source.contains("cigarettesHabitRow.swipeLeft()"))
        // The UUID stays in the selector string (the stable contract) but never in an identifier.
        XCTAssertFalse(result.source.contains("let a40fb286"))
        XCTAssertFalse(result.source.contains("a40fb286E7ca"))
        for line in result.source.split(separator: "\n") where line.contains("let ") && line.contains("Row =") {
            XCTAssertTrue(line.contains("let cigarettesHabitRow ="))
        }
    }

    func testXCUITestEmitterAppendsNumericSuffixForDuplicateLabels() throws {
        // Two distinct selectors that both derive `cigarettes` must get distinct, deterministic names.
        let test = makeTest(operations: [
            .init(id: "s0", tool: "tap_element", arguments: ["label": "Cigarettes"]),
            .init(id: "s1", tool: "tap_element", arguments: ["contains_text": "Cigarettes"])
        ])

        let result = try XCUITestEmitter().generate(test)

        XCTAssertTrue(result.source.contains("let cigarettes ="))
        XCTAssertTrue(result.source.contains("let cigarettes2 ="))
        XCTAssertFalse(result.source.contains("let cigarettes3 ="))
    }
}
