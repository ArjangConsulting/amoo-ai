import StudioProtocol
@testable import TestCodeGenerator
import XCTest

/// A wrong binding silently changes what the generated test does, so these cover the two ways
/// that happens: a helper that ignores an argument the step depends on, and a helper whose name
/// merely contains a verb's letters.
final class HelperBinderTests: XCTestCase {
    private func makeTest(
        helpers: [StudioTestContext.Helper],
        operations: [StudioToolOperation]
    ) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Binder",
            description: "",
            platform: .ios,
            steps: [],
            testContext: StudioTestContext(helpers: helpers),
            compiledPlan: .init(compiler: "session", compilerVersion: "1", toolOperations: operations)
        )
    }

    private func boundHelpers(_ test: StudioAuthoredTest) -> [String?] {
        HelperBinder.bindingContextHelpers(test).compiledPlan?.toolOperations?.map(\.helper) ?? []
    }

    func testBindsAnUnambiguousHelperThatConsumesEveryMeaningfulArgument() {
        let test = makeTest(
            helpers: [.init(name: "tapById", callTemplate: "tapById({{id}})")],
            operations: [.init(id: "step-0", tool: "tap_element", arguments: ["id": "next", "timeout_ms": "3000"])]
        )

        // `timeout_ms` is incidental — a helper may ignore it and still be the right binding.
        XCTAssertEqual(boundHelpers(test), ["tapById"])
    }

    func testDoesNotBindAHelperThatWouldDropTheTextBeingTyped() {
        let test = makeTest(
            helpers: [.init(name: "fillField", callTemplate: "fillField(id: {{id}})")],
            operations: [.init(id: "step-0", tool: "set_text", arguments: ["id": "email", "value": "a@b.com"])]
        )

        XCTAssertEqual(boundHelpers(test), [nil])
    }

    func testDoesNotBindOnASubstringOfAVerb() {
        // "tapCenter" contains the letters of set_text's "enter", but is not a set_text helper.
        let test = makeTest(
            helpers: [.init(name: "tapCenter", callTemplate: "tapCenter(id: {{id}}, value: {{value}})")],
            operations: [.init(id: "step-0", tool: "set_text", arguments: ["id": "email", "value": "a@b.com"])]
        )

        XCTAssertEqual(boundHelpers(test), [nil])
    }

    func testDoesNotBindWhenTwoHelpersQualify() {
        let test = makeTest(
            helpers: [
                .init(name: "tapById", callTemplate: "tapById({{id}})"),
                .init(name: "pressById", callTemplate: "pressById({{id}})")
            ],
            operations: [.init(id: "step-0", tool: "tap_element", arguments: ["id": "next"])]
        )

        XCTAssertEqual(boundHelpers(test), [nil])
    }

    func testNeverOverridesAHelperThePlannerAlreadyChose() {
        let test = makeTest(
            helpers: [
                .init(name: "tapById", callTemplate: "tapById({{id}})"),
                .init(name: "signIn", callTemplate: "signIn({{id}})")
            ],
            operations: [.init(id: "step-0", tool: "tap_element", arguments: ["id": "next"], helper: "signIn")]
        )

        XCTAssertEqual(boundHelpers(test), ["signIn"])
    }
}
