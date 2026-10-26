// swiftlint:disable multiline_arguments
import AmooCore
import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// Selected-state assertions and AND-combined selectors in generated source.
final class SelectedAssertionCodegenTests: XCTestCase {
    private func test(
        _ operations: [StudioToolOperation],
        platform: Platform = .ios,
        context: StudioTestContext? = nil
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1, name: "Selection", description: "", platform: platform,
            steps: [.init(id: "s", instruction: "Select", expected: "Selected")],
            testContext: context,
            compiledPlan: .init(compiler: "t", compilerVersion: "1", toolOperations: operations)
        )
    }

    private func operation(_ tool: String, _ arguments: [String: String]) -> StudioToolOperation {
        .init(id: "op", tool: tool, arguments: arguments)
    }

    private func xcui(_ operations: [StudioToolOperation], context: StudioTestContext? = nil) throws -> String {
        try XCUITestEmitter().generate(test(operations, context: context)).source
    }

    // MARK: - assert_selected

    func testEmitsAnExplicitPositiveAndNegativeSelectionCheck() throws {
        let source = try xcui([
            operation("assert_selected", ["id": "day.10", "expected": "true"]),
            operation("assert_selected", ["id": "day.11", "expected": "false", "timeout_ms": "2500"])
        ])
        XCTAssertTrue(source.contains(#"waitForExistence(day, named: "day", timeout: 5.0)"#), source)
        XCTAssertTrue(source.contains(#"waitForSelection(day, expected: true, named: "day", timeout: 5.0)"#), source)
        XCTAssertTrue(source.contains(#"waitForSelection(day2, expected: false, named: "day2", timeout: 2.5)"#), source)
        XCTAssertTrue(source.contains("element.wait(for: \\.isSelected, toEqual: expected"), source)
        XCTAssertFalse(source.contains("waitForHittability(day"), "selection is not substituted by hittability")
    }

    func testTheSelectionHelperNamesTheExpectedAndObservedState() throws {
        let source = try xcui([operation("assert_selected", ["id": "day.10", "expected": "true"])])
        XCTAssertTrue(source.contains(#"expected to be \(expected ? "selected" : "unselected")"#), source)
        XCTAssertTrue(source.contains(#"isSelected was"#), source)
    }

    func testAnOmittedOrUnrecognisedExpectationIsRejectedNotDefaulted() {
        XCTAssertThrowsError(try xcui([operation("assert_selected", ["id": "day.10"])])) {
            XCTAssertEqual(
                $0 as? TestCodeGeneratorError,
                .missingArgument(tool: "assert_selected", argument: "expected")
            )
        }
        XCTAssertThrowsError(try xcui([operation("assert_selected", ["id": "day.10", "expected": "yes"])])) {
            XCTAssertEqual(
                $0 as? TestCodeGeneratorError,
                .invalidArgument(tool: "assert_selected", argument: "expected", value: "yes")
            )
        }
    }

    func testAnAssertionBindingMustCarryTheSelectedState() throws {
        let dropping = StudioTestContext(assertionBindings: ["assert_selected": "expectSelected({{element}})"])
        XCTAssertThrowsError(
            try xcui([operation("assert_selected", ["id": "day.10", "expected": "false"])], context: dropping)
        ) {
            guard case .invalidArgument(_, "assertionBindings", _)? = $0 as? TestCodeGeneratorError else {
                return XCTFail("\($0)")
            }
        }

        let keeping = StudioTestContext(
            assertionBindings: ["assert_selected": "expectSelected({{element}}, {{selected}})"]
        )
        let source = try xcui([
            operation("assert_selected", ["id": "day.10", "expected": "true"]),
            operation("assert_selected", ["id": "day.11", "expected": "false"])
        ], context: keeping)
        XCTAssertTrue(source.contains("expectSelected(day, true)"), source)
        XCTAssertTrue(source.contains("expectSelected(day2, false)"), source)
        XCTAssertFalse(source.contains("waitForSelection("), "the repository's own helper replaces ours")
    }

    func testABoundHelperMustTakeTheExpectation() throws {
        let context = StudioTestContext(helpers: [
            .init(name: "checkDay", callTemplate: "checkDay({{id}})")
        ])
        var bound = operation("assert_selected", ["id": "day.10", "expected": "true"])
        bound = bound.bindingHelper("checkDay")
        XCTAssertThrowsError(try xcui([bound], context: context)) {
            guard case .invalidArgument(_, "helper", _)? = $0 as? TestCodeGeneratorError else {
                return XCTFail("\($0)")
            }
        }
    }

    func testAHelperIsNeverBoundToASelectionAssertionByNameAlone() {
        let context = StudioTestContext(helpers: [
            .init(name: "assertDayVisible", callTemplate: "assertDayVisible({{id}})")
        ])
        let original = test([operation("assert_selected", ["id": "day.10", "expected": "true"])], context: context)
        let bound = HelperBinder.bindingContextHelpers(original)
        XCTAssertNil(bound.compiledPlan?.toolOperations?.first?.helper)
    }

    func testAndroidEmittersAssertActualSelection() throws {
        let plan = test([operation("assert_selected", ["id": "day.10", "expected": "true"])], platform: .android)
        let espresso = try EspressoEmitter().generate(plan).source
        let compose = try ComposeEspressoEmitter().generate(plan).source
        XCTAssertTrue(espresso.contains("isSelected()"))
        XCTAssertTrue(compose.contains("SemanticsProperties.Selected, true"))
    }

    func testAndroidNativeStateAssertionsCompileAndPreserveTheirProperties() throws {
        let plan = test([
            operation("assert_selected", ["id": "option", "expected": "false"]),
            operation("assert_checked", ["id": "checkbox", "expected": "false"]),
            operation("assert_state_description", ["id": "copy", "expected": "Copied"]),
            operation("assert_state_description", ["id": "copy", "contains": "Copy"]),
            operation("assert_state_description", ["id": "copy", "expected": ""])
        ], platform: .android)
        let espresso = try EspressoEmitter().generate(plan).source
        XCTAssertTrue(espresso.contains("not(isSelected())"), espresso)
        XCTAssertTrue(espresso.contains("not(isChecked())"), espresso)
        XCTAssertTrue(espresso.contains("view.stateDescription"), espresso)
        XCTAssertFalse(espresso.contains("withText("), espresso)
        try CompileVerification.verifyKotlinCompiles(espresso)
        let compose = try ComposeEspressoEmitter().generate(plan).source
        XCTAssertTrue(compose.contains("SemanticsProperties.ToggleableState"), compose)
        XCTAssertTrue(compose.contains("SemanticsProperties.StateDescription"), compose)
        try CompileVerification.verifyKotlinCompiles(compose)
    }

    func testXCUITestRejectsUnsupportedNativeStateAssertions() {
        for tool in ["assert_checked", "assert_state_description"] {
            XCTAssertThrowsError(try xcui([operation(tool, ["id": "option", "expected": "false"])]))
        }
    }

    // MARK: - XCUITest selector constraints

    func testAnIdentifierAloneKeepsTheSubscriptForm() throws {
        let source = try xcui([operation("assert_visible", ["id": "day.10"])])
        XCTAssertTrue(source.contains(#"let day = app.descendants(matching: .any)["day.10"]"#), source)
    }

    func testIdentifierAndTextConstraintsAreBothApplied() throws {
        let source = try xcui([operation("assert_visible", ["id": "day.10", "contains_text": "Range end"])])
        XCTAssertTrue(
            source.contains(#"""
            app.descendants(matching: .any).matching(identifier: "day.10")\#
            .matching(NSPredicate(format: "label CONTAINS %@", "Range end")).firstMatch
            """#),
            source
        )
    }

    func testIdentifierLabelAndTextAreAllApplied() throws {
        let source = try xcui([
            operation("tap_element", ["id": "day.10", "label": "Friday", "contains_text": "start"])
        ])
        XCTAssertTrue(source.contains(#".matching(identifier: "day.10")"#), source)
        XCTAssertTrue(source.contains(#".matching(NSPredicate(format: "label == %@", "Friday"))"#), source)
        XCTAssertTrue(source.contains(#".matching(NSPredicate(format: "label CONTAINS %@", "start"))"#), source)
    }

    func testLabelAndContainsOnlySelectorsAreUnchanged() throws {
        let source = try xcui([
            operation("assert_visible", ["label": "Welcome"]),
            operation("assert_visible", ["contains_text": "Welc"])
        ])
        XCTAssertTrue(
            source
                .contains(
                    // swiftlint:disable:next line_length
                    #"app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Welcome")).firstMatch"#
                ),
            source
        )
        XCTAssertTrue(
            source
                .contains(
                    // swiftlint:disable:next line_length
                    #"app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Welc")).firstMatch"#
                ),
            source
        )
    }

    func testParentScopeIsAppliedBeforeConstraintsAndThePickAfterThem() throws {
        let source = try xcui([
            operation(
                "assert_visible",
                ["id": "day.10", "parent_id": "month.oct", "contains_text": "start", "index": "1"]
            )
        ])
        XCTAssertTrue(
            source.contains(#"""
            app.descendants(matching: .any)["month.oct"].descendants(matching: .any)\#
            .matching(identifier: "day.10").matching(NSPredicate(format: "label CONTAINS %@", "start"))\#
            .element(boundBy: 1)
            """#),
            source
        )
    }

    func testParentScopeAlsoScopesALoneIdentifier() throws {
        let source = try xcui([operation("tap_element", ["id": "day.10", "parent_id": "month.oct"])])
        XCTAssertTrue(
            source.contains(#"""
            app.descendants(matching: .any)["month.oct"].descendants(matching: .any)\#
            .matching(identifier: "day.10").firstMatch
            """#),
            source
        )
    }

    func testMappedIdentifiersKeepTheirExpressionInACombinedQuery() throws {
        let context = StudioTestContext(selectorExpressions: ["day.10": "AppID.day10", "month.oct": "AppID.october"])
        let source = try xcui(
            [operation("assert_visible", ["id": "day.10", "parent_id": "month.oct", "contains_text": "x"])],
            context: context
        )
        XCTAssertTrue(
            source.contains("app.descendants(matching: .any)[AppID.october].descendants(matching: .any)"),
            source
        )
        XCTAssertTrue(source.contains(".matching(identifier: AppID.day10)"), source)
    }

    func testAnElementScopedGestureAppliesBothTheIdAndTheLabel() throws {
        let source = try xcui([
            operation("swipe_in_direction", ["direction": "left", "element_id": "row.1", "element_label": "Groceries"])
        ])
        XCTAssertTrue(source.contains(#".matching(identifier: "row.1")"#), source)
        XCTAssertTrue(source.contains(#".matching(NSPredicate(format: "label == %@", "Groceries"))"#), source)
    }

    func testANamingHintNeverBecomesAConstraint() throws {
        let source = try xcui([
            operation("swipe_in_direction", ["direction": "left", "element_id": "row.1", "name_hint": "Groceries"])
        ])
        XCTAssertFalse(source.contains("NSPredicate"), source)
        XCTAssertTrue(source.contains(#"app.descendants(matching: .any)["row.1"]"#), source)
    }

    // MARK: - Android selector constraints

    func testEspressoRequiresEveryConstraintAndTheAncestor() throws {
        let source = try EspressoEmitter().generate(test([
            operation("assert_visible", ["id": "day.10", "contains_text": "Range end", "parent_id": "month.oct"])
        ], platform: .android)).source
        XCTAssertTrue(source.contains("allOf(anyOf(hasResourceEntryName(\"day.10\")"), source)
        XCTAssertTrue(source.contains("containsString(\"Range end\")"), source)
        XCTAssertTrue(source.contains("isDescendantOfA(anyOf(hasResourceEntryName(\"month.oct\")"), source)
        XCTAssertTrue(source.contains("import org.hamcrest.Matchers.allOf"), source)
        XCTAssertTrue(source.contains("import androidx.test.espresso.matcher.ViewMatchers.isDescendantOfA"), source)
        try CompileVerification.verifyKotlinCompiles(source)
    }

    func testEspressoSingleConstraintOutputIsUnchanged() throws {
        let source = try EspressoEmitter().generate(test([
            operation("assert_visible", ["id": "day.10"])
        ], platform: .android)).source
        XCTAssertFalse(source.contains("allOf("), source)
        XCTAssertFalse(source.contains("isDescendantOfA"), source)
    }

    func testComposeRequiresEveryConstraintAndTheAncestor() throws {
        let source = try ComposeEspressoEmitter().generate(test([
            operation("assert_visible", ["id": "day.10", "label": "Friday", "parent_id": "month.oct"])
        ], platform: .android)).source
        XCTAssertTrue(
            source
                .contains(
                    // swiftlint:disable:next line_length
                    #"hasTestTag("day.10") and hasContentDescription("Friday") and hasAnyAncestor(hasTestTag("month.oct"))"#
                ),
            source
        )
        XCTAssertTrue(source.contains("import androidx.compose.ui.test.hasAnyAncestor"), source)
        try CompileVerification.verifyKotlinCompiles(source)
    }
}

// swiftlint:enable multiline_arguments
