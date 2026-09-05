import AmooCore
import Foundation
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

// Compact, inline report fixtures are easier to audit when their related fields remain together.
// swiftlint:disable line_length multiline_arguments
// swiftlint:disable:next type_body_length
final class SessionPlanCompilerTests: XCTestCase {
    private func makeAction(
        tool: String,
        arguments: [String: String] = [:],
        isError: Bool = false
    ) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: isError)
    }

    private func makeReport(actions: [SessionAction]) -> SessionReport {
        SessionReport(
            sessionID: "session-1",
            appID: "com.example.app",
            deviceID: "device-1",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 12,
            actionCount: actions.count,
            errorCount: actions.filter(\.isError).count,
            isActive: false,
            actions: actions
        )
    }

    func testCoordinateSwipeUsesPriorResolvedElementAndSemanticNameAndLaunchConfiguration() throws {
        let lookup = SessionAction(
            timestamp: Date(), toolName: "find_elements", arguments: ["contains_text": "Groceries"],
            result: "Found 1 element(s):\n\u{001B}[34m[app.task.row.groceries]\u{001B}[0m Groceries hitPoint: (201,257) pts 370x94",
            isError: false, intent: .diagnostic,
            observedElements: [.init(
                id: "app.task.row.groceries", label: "Groceries",
                frame: .init(x: 16, y: 210, width: 370, height: 94), hitPoint: .init(x: 201, y: 257)
            )]
        )
        let swipe = makeAction(tool: "swipe", arguments: [
            "from_x": "340", "from_y": "257", "to_x": "55", "to_y": "257", "duration_ms": "400"
        ])
        let interveningQuery = SessionAction(
            timestamp: Date(),
            toolName: "get_screen_context",
            arguments: [:],
            result: "Tasks",
            isError: false,
            intent: .diagnostic
        )
        let base = makeReport(actions: [
            lookup, interveningQuery, swipe, makeAction(tool: "tap_element", arguments: ["label": "Add"])
        ])
        let report = SessionReport(
            sessionID: base.sessionID, appID: base.appID, deviceID: base.deviceID, platform: base.platform,
            startedAt: base.startedAt, endedAt: base.endedAt, durationSeconds: base.durationSeconds,
            actionCount: base.actionCount, errorCount: 0, isActive: false, actions: base.actions,
            launchArguments: ["-AppleLanguages", "(en)"],
            launchEnvironment: ["APP_UI_TEST_SKIP_ONBOARDING": "1", "APP_AUTOMATED_TESTING": "1"]
        )

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let swipeOperation = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations?.first {
            $0.tool == "swipe_in_direction"
        })
        XCTAssertEqual(swipeOperation.arguments["element_id"], "app.task.row.groceries")
        XCTAssertEqual(swipeOperation.arguments["direction"], "left")
        // No caller/recording name: the fallback reports only what is certain (the skip-onboarding
        // launch flag) rather than guessing verbs from the tool mix.
        XCTAssertEqual(result.studioTest.name, "skipOnboardingFlow")
        XCTAssertEqual(result.studioTest.requirements?.launchArguments, ["-AppleLanguages", "(en)"])
        XCTAssertEqual(result.studioTest.requirements?.launchEnvironment["APP_AUTOMATED_TESTING"], "1")
        XCTAssertFalse(result.warnings.contains { $0.kind == .excluded && $0.toolName == "swipe" })
    }

    func testLegacyTextObservationStillAssociatesAcrossNonMutatingDiagnostics() throws {
        let lookup = SessionAction(
            timestamp: Date(), toolName: "find_elements", arguments: ["contains_text": "Groceries"],
            result: "Found 1 element(s):\n\u{001B}[34m[legacy.groceries]\u{001B}[0m Groceries hitPoint: (201,257) pts 370x94",
            isError: false, intent: .diagnostic
        )
        let report = makeReport(actions: [
            lookup,
            SessionAction(
                timestamp: Date(),
                toolName: "take_screenshot_metadata",
                arguments: [:],
                result: "ok",
                isError: false,
                intent: .diagnostic
            ),
            makeAction(tool: "swipe", arguments: [
                "from_x": "340", "from_y": "257", "to_x": "55", "to_y": "257"
            ])
        ])
        let operations = try XCTUnwrap(SessionPlanCompiler.compile(
            report: report, testName: nil, testDescription: nil
        ).studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.last?.tool, "swipe_in_direction")
        XCTAssertEqual(operations.last?.arguments["element_id"], "legacy.groceries")
    }

    func testExplicitSessionNameWinsOverSemanticFallback() throws {
        let base = makeReport(actions: [makeAction(tool: "tap_element", arguments: ["id": "go"])])
        let report = SessionReport(
            sessionID: base.sessionID, appID: base.appID, deviceID: base.deviceID, platform: base.platform,
            startedAt: base.startedAt, endedAt: base.endedAt, durationSeconds: base.durationSeconds,
            actionCount: base.actionCount, errorCount: 0, isActive: false, actions: base.actions,
            testName: "My explicit flow!"
        )
        XCTAssertEqual(
            try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil).studioTest.name,
            "My explicit flow!"
        )
    }

    func testObservedLabelIsAttachedAsNamingHintForNamespacedIDOnly() throws {
        func find(_ id: String, _ label: String) -> SessionAction {
            SessionAction(
                timestamp: Date(), toolName: "find_elements", arguments: ["contains_text": label],
                result: "Found 1 element(s)", isError: false, intent: .diagnostic,
                observedElements: [.init(id: id, label: label, frame: nil, hitPoint: nil)]
            )
        }
        let report = makeReport(actions: [
            find("app.task_list.create_button", "New Task"),
            makeAction(tool: "tap_element", arguments: ["id": "app.task_list.create_button"]),
            find("trash", "Delete"),
            makeAction(tool: "tap_element", arguments: ["id": "trash"])
        ])
        let ops = try XCTUnwrap(
            SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
                .studioTest.compiledPlan?.toolOperations
        )
        let create = try XCTUnwrap(ops.first { $0.arguments["id"] == "app.task_list.create_button" })
        // Namespaced id → the label rides along as a naming hint, never as the selector.
        XCTAssertEqual(create.arguments["name_hint"], "New Task")
        XCTAssertNil(create.arguments["label"])
        // Self-descriptive id → left alone, so `trash` stays `trash` rather than colliding on "Delete".
        let trash = try XCTUnwrap(ops.first { $0.arguments["id"] == "trash" })
        XCTAssertNil(trash.arguments["name_hint"])
        XCTAssertNil(trash.arguments["label"])
    }

    func testHappyPathTranslatesRecognizedTools() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["id": "submit-button"]),
            makeAction(tool: "type_text", arguments: ["text": "hello"]),
            makeAction(tool: "assert_visible", arguments: ["description": "Welcome screen"]),
            makeAction(tool: "take_screenshot")
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.platform, "ios")
        XCTAssertEqual(result.testFlow.deviceID, "device-1")
        XCTAssertEqual(result.testFlow.steps.map(\.tool), [
            "tap_element", "type_text", "assert_visible", "take_screenshot"
        ])
        XCTAssertEqual(result.testFlow.steps[0].arguments["id"], "submit-button")

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["tap_element", "type_text", "assert_visible", "take_screenshot"])
        XCTAssertEqual(operations[2].arguments["contains_text"], "Welcome screen")
        XCTAssertNil(operations[2].arguments["description"])

        XCTAssertEqual(result.studioTest.steps.count, 4)
        XCTAssertEqual(result.studioTest.platform, .ios)
        XCTAssertEqual(result.studioTest.requirements?.appId, "com.example.app")

        // assert_visible is flagged approximate (description -> contains_text), everything else is clean.
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "assert_visible")
    }

    func testRedactedValuePassesThroughWithWarning() throws {
        let report = makeReport(actions: [
            makeAction(tool: "set_text", arguments: ["id": "password-field", "value": "<redacted, 8 chars>"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operation = result.studioTest.compiledPlan?.toolOperations?.first
        XCTAssertEqual(operation?.arguments["value"], "<redacted, 8 chars>")
        XCTAssertEqual(result.testFlow.steps.first?.arguments["value"], "<redacted, 8 chars>")
        XCTAssertTrue(result.warnings.contains { $0.reason.contains("redacted") })
    }

    func testFailedProbeIsNeverEmittedAsAnExecutableOperation() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["id": "obsolete-alcohol"], isError: true),
            makeAction(tool: "tap_element", arguments: ["id": "continue"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations?.map { $0.arguments["id"] }, ["continue"])
        XCTAssertTrue(result.warnings.contains {
            $0.toolName == "tap_element" && $0.reason.contains("failed exploratory action")
        })
    }

    func testAssertValuePreservesValueSemantics() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_value", arguments: ["id": "chore", "expected": "0"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operation = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations?.first)
        XCTAssertEqual(operation.tool, "assert_value")
        XCTAssertEqual(operation.arguments["value"], "0")
    }

    func testUntranslatableCoordinateTapIsExcludedFromCompiledPlanButKeptInFlow() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap", arguments: ["x": "10", "y": "20"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.steps.map(\.tool), ["tap"])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "tap")
        // A coordinate tap gets an actionable message: where it landed, why it could not compile,
        // and what to change — not the bare "no Studio tool equivalent".
        XCTAssertTrue(result.warnings[0].reason.contains("(10, 20)"))
        XCTAssertTrue(result.warnings[0].reason.contains("accessibility identifier"))
        XCTAssertTrue(result.warnings[0].reason.contains("re-record"))
    }

    func testTrailingInspectionBeforeATransitionCompilesIntoAnAssertion() throws {
        let report = makeReport(actions: [
            makeAction(tool: "find_elements", arguments: ["id": "word-details-sheet"]),
            makeAction(tool: "tap_element", arguments: ["id": "close-button"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        // The inspection stood in for "I checked the sheet was up"; it becomes an assertion rather
        // than being dropped, so the generated test actually verifies the screen.
        XCTAssertEqual(operations.map(\.tool), ["assert_visible", "tap_element"])
        XCTAssertEqual(operations[0].arguments["id"], "word-details-sheet")
        XCTAssertTrue(result.warnings.contains { $0.toolName == "find_elements" && $0.kind == .approximate })
    }

    func testInspectionWithNoAssertableSelectorSuggestsAddingAnAssertion() throws {
        let report = makeReport(actions: [
            makeAction(tool: "describe_screen"),
            makeAction(tool: "tap_element", arguments: ["id": "next"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations?.map(\.tool), ["tap_element"])
        let inspection = try XCTUnwrap(result.warnings.first { $0.toolName == "describe_screen" })
        XCTAssertEqual(inspection.kind, .notApplicable)
        XCTAssertTrue(inspection.reason.contains("consider adding an explicit assertion"))
    }

    func testConsecutiveIdenticalRetryTapsCollapseToOneGuardedStep() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["id": "retry"]),
            makeAction(tool: "tap_element", arguments: ["id": "retry"]),
            makeAction(tool: "tap_element", arguments: ["id": "retry"]),
            makeAction(tool: "tap_element", arguments: ["id": "continue"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        // The literal flow still replays every tap; the compiled plan collapses the retry run.
        XCTAssertEqual(result.testFlow.steps.count, 4)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map { $0.arguments["id"] }, ["retry", "continue"])
        XCTAssertTrue(result.warnings.contains { $0.reason.contains("3 identical taps") })
        // The warning has to say the collapse is a guess, or a cumulative tap run is lost silently.
        XCTAssertTrue(result.warnings.contains { $0.reason.contains("restore all 3 taps") })
    }

    func testDeliberatelyRepeatedTapsAreNotCollapsed() throws {
        // A stepper being incremented: identical taps, but paced by a person rather than hammered.
        let start = Date()
        let actions = (0 ..< 3).map { index in
            SessionAction(
                timestamp: start.addingTimeInterval(Double(index) * 2),
                toolName: "tap_element",
                arguments: ["id": "quantity.increment"],
                result: "ok",
                isError: false
            )
        }

        let result = try SessionPlanCompiler.compile(
            report: makeReport(actions: actions),
            testName: nil,
            testDescription: nil
        )

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.count, 3)
        XCTAssertFalse(result.warnings.contains { $0.reason.contains("quick succession") })
    }

    func testSystemUIActionsAreTaggedTransient() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["label": "Allow Notifications"]),
            makeAction(tool: "tap", arguments: ["x": "1", "y": "2", "note": "com.apple.springboard alert"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertTrue(result.warnings.contains { $0.toolName == "tap_element" && $0.transient })
        XCTAssertTrue(result.warnings.contains { $0.toolName == "tap" && $0.transient })

        // And transient survives the JSON round-trip into the saved plan.
        let data = try JSONEncoder().encode(result.studioTest)
        let decoded = try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
        XCTAssertTrue((decoded.compiledPlan?.warnings ?? []).contains { $0.transient })
    }

    func testAppOwnedIdentifiersAreNotMistakenForTransientOverlays() throws {
        // A `transient` false positive tells the finalize pass a real step is disposable, so overlay
        // words must not match inside an app's own identifiers, nor as a substring of a longer word.
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["id": "settings.permissions.row"]),
            makeAction(tool: "tap_element", arguments: ["id": "app.paywall.subscribe.button"]),
            makeAction(tool: "tap_element", arguments: ["label": "Paywalls are great"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertFalse(result.warnings.contains(where: \.transient))
    }

    func testOverlayWordsInHumanFacingTextAreTaggedTransient() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["label": "Dismiss paywall"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertTrue(result.warnings.contains(where: \.transient))
    }

    func testPlanWarningWithoutTransientKeyStillDecodes() throws {
        let json = Data(#"{"kind":"excluded","actionIndex":0,"toolName":"tap","reason":"x"}"#.utf8)
        let warning = try JSONDecoder().decode(StudioPlanWarning.self, from: json)
        XCTAssertFalse(warning.transient)
    }

    func testDescriptionOnlyAssertionsRetainAStudioSelector() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_absent", arguments: ["description": "Loading spinner"]),
            makeAction(
                tool: "assert_value",
                arguments: ["description": "Account status", "expected": "Active"]
            )
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        XCTAssertEqual(operations.map(\.tool), ["assert_not_visible", "assert_value"])
        XCTAssertEqual(operations[0].arguments["contains_text"], "Loading spinner")
        XCTAssertEqual(operations[1].arguments["contains_text"], "Account status")
        XCTAssertEqual(operations[1].arguments["value"], "Active")
        XCTAssertTrue(result.warnings.allSatisfy { $0.reason.contains("approximate selector mapping") })
    }

    func testAssertEnabledTranslatesToStudioTool() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_enabled", arguments: ["id": "submit-button"]),
            makeAction(tool: "assert_enabled", arguments: ["description": "Play button"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        XCTAssertEqual(operations.map(\.tool), ["assert_enabled", "assert_enabled"])
        XCTAssertEqual(operations[0].arguments["id"], "submit-button")
        XCTAssertEqual(operations[1].arguments["contains_text"], "Play button")
        XCTAssertNil(operations[1].arguments["description"])

        // Only the description-only selector (approximate mapping) should warn.
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "assert_enabled")
    }

    func testScrollTranslatesAndKeepsItsOwnDirectionSemantics() throws {
        let report = makeReport(actions: [
            makeAction(tool: "scroll", arguments: ["direction": "down", "distance": "400"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        // scroll must stay its own tool rather than being folded into swipe_in_direction: the two
        // have inverted direction semantics, so collapsing them would reverse every recorded scroll.
        XCTAssertEqual(operations.map(\.tool), ["scroll"])
        XCTAssertEqual(operations[0].arguments["direction"], "down")
        XCTAssertEqual(operations[0].arguments["distance"], "400")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testWarningsArePersistedInsideTheCompiledPlan() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap", arguments: ["x": "10", "y": "20"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        // The saved plan itself must carry the warning, not just the compile result — otherwise a
        // plan read back off disk cannot tell that a step went missing.
        let planWarnings = try XCTUnwrap(result.studioTest.compiledPlan?.warnings)
        XCTAssertEqual(planWarnings.map(\.toolName), ["tap"])
        XCTAssertEqual(planWarnings.map(\.kind), [.excluded])
        XCTAssertEqual(result.studioTest.compiledPlan?.excludedWarnings.count, 1)

        // And it must survive a JSON round-trip, which is how it actually reaches `generate test`.
        let data = try JSONEncoder().encode(result.studioTest)
        let decoded = try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
        XCTAssertEqual(decoded.compiledPlan?.excludedWarnings.map(\.toolName), ["tap"])
    }

    func testInspectionOnlyToolsAreMarkedNotApplicableRatherThanExcluded() throws {
        let report = makeReport(actions: [
            makeAction(tool: "find_elements", arguments: ["label": "Submit"]),
            makeAction(tool: "describe_screen")
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        // Query tools legitimately have no place in generated code. They must not be reported as
        // vocabulary gaps, or every session would look broken and the refusal would cry wolf.
        XCTAssertEqual(result.warnings.map(\.kind), [.notApplicable, .notApplicable])
        XCTAssertEqual(result.studioTest.compiledPlan?.excludedWarnings, [])
    }

    func testContainsOnlyValueAssertionIsExcludedRatherThanChangedToEquality() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_value", arguments: ["id": "message", "contains": "Welcome"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.steps.map(\.tool), ["assert_value"])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].reason.contains("no Studio tool equivalent"))
    }

    func testFlowEncodesRecordedDeviceUsingCLIFieldName() throws {
        let result = try SessionPlanCompiler.compile(
            report: makeReport(actions: [makeAction(tool: "press_back")]),
            testName: nil,
            testDescription: nil
        )

        let data = try JSONEncoder().encode(result.testFlow)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, "device-1")
        XCTAssertNil(json["deviceID"])
    }

    func testEmptySessionProducesEmptyResult() throws {
        let report = makeReport(actions: [])

        let result = try SessionPlanCompiler.compile(
            report: report,
            testName: "custom-name",
            testDescription: "custom-desc"
        )

        XCTAssertEqual(result.testFlow.steps, [])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.studioTest.name, "custom-name")
        XCTAssertEqual(result.studioTest.description, "custom-desc")
        XCTAssertTrue(result.warnings.isEmpty)
    }
}

// swiftlint:enable line_length multiline_arguments
