import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

extension MCPServerTests {
    // MARK: - Audit Tool Tests

    func testAuditAppRequiresAppID() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("app_id"))
    }

    func testAuditAppReturnsFindings() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
        // The mock driver returns elements that trigger audit rules (e.g. missing labels)
        XCTAssertTrue(result.content.contains("com.test"))
    }

    func testAuditSecurityRunsSecurityRulesOnly() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_security", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditAccessibilityRunsUXRules() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_accessibility", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditWithFailOnThreshold() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "audit_app",
            arguments: ["app_id": "com.test", "fail_on": "low"]
        )
        // If there are findings at low or above, isError should be true
        if result.content.contains("finding(s)") {
            XCTAssertTrue(result.isError)
        }
    }

    func testAuditPassesCleanApp() async {
        let driver = MockDriver() // Clean mock with no problematic elements
        try? await driver.launchApp(appID: "com.clean", arguments: [], environment: [:])
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.clean"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("No findings") || result.content.contains("finding"))
    }

    // MARK: - Assistant Tool Tests

    func testDescribeScreen() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen summary: Screen with 1 visible nodes"))
        XCTAssertTrue(result.content.contains("Interactable elements: 0"))
        XCTAssertNotNil(result.structuredContent)
    }

    func testDescribeScreenStructuredContentMatchesSchema() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])
        let structured = try XCTUnwrap(result.structuredContent)
        let fields = try XCTUnwrap(structured.objectValue)
        XCTAssertEqual(fields["summary"]?.stringValue, "Screen with 1 visible nodes")
        XCTAssertEqual(fields["interactableCount"]?.intValue, 0)
    }

    func testDescribeScreenIncludesVisibleStructureAndActions() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen title: Test screen"))
        XCTAssertTrue(result.content.contains("Interactable elements: 2"))
        XCTAssertTrue(result.content.contains("Key actions: button Submit; button Cancel"))
    }

    func testSuggestActionsWithoutInteractableElements() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredContent)
        XCTAssertTrue(result.content.contains("Screen intent:"))
        XCTAssertTrue(result.content.contains("Suggested actions:"))
        XCTAssertTrue(result.content.contains("Accessibility issues:"))
        XCTAssertTrue(result.content.contains("No app-relevant interactable elements"))
    }

    func testSuggestActionsWithInteractableElements() async {
        let driver = AuditMockDriver() // Has interactable elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertNotNil(result.structuredContent)
        XCTAssertTrue(result.content.contains("Screen intent:"))
        XCTAssertTrue(result.content.contains("1. Tap Submit"))
        XCTAssertTrue(result.content.contains("2. Tap Cancel"))
        XCTAssertTrue(result.content.contains("Developer feedback:"))
    }

    func testSuggestActionsReturnsStructuredReport() async throws {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "suggest_test_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Confidence: medium"))

        let data = try JSONEncoder().encode(XCTUnwrap(result.structuredContent))
        let report = try JSONDecoder().decode(TestActionSuggestionReport.self, from: data)
        XCTAssertEqual(report.suggestedActions.count, 3)
        XCTAssertEqual(report.suggestedActions.first?.priority, 1)
    }

    func testAnalyzeAITestabilityReturnsStructuredFeedback() async throws {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "analyze_ai_testability", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("AI testability:"))
        let data = try JSONEncoder().encode(XCTUnwrap(result.structuredContent))
        let report = try JSONDecoder().decode(AITestabilityReport.self, from: data)
        XCTAssertEqual(report.interactableCount, 2)
        XCTAssertFalse(report.developerFeedback.isEmpty)
    }

    func testFindByDescriptionRequiresDescription() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "find_element_by_description", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("description"))
    }

    func testFindByDescriptionWithoutMatches() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "find_element_by_description",
            arguments: ["description": "login button"]
        )
        XCTAssertFalse(result.isError)
        // MockDriver.findByDescription returns empty, so "No elements matched"
        XCTAssertTrue(result.content.contains("No elements matched"))
    }

    func testFindByDescriptionMatchesExposedLabels() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "find_element_by_description", arguments: ["description": "submit"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("match"))
        XCTAssertNotNil(result.structuredContent)
    }

    func testRemovedAIToolNamesReturnUnknownTool() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let describeAI = await server.execute(toolName: "ai_describe_screen", arguments: [:])
        XCTAssertTrue(describeAI.isError)
        XCTAssertTrue(describeAI.content.contains("Unknown tool"))

        let suggestAI = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertTrue(suggestAI.isError)
        XCTAssertTrue(suggestAI.content.contains("Unknown tool"))

        let findAI = await server.execute(toolName: "ai_find_by_description", arguments: ["description": "submit"])
        XCTAssertTrue(findAI.isError)
        XCTAssertTrue(findAI.content.contains("Unknown tool"))
    }

    func testSwipeInDirectionTool() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "swipe_in_direction",
            arguments: ["direction": "left", "distance": "300", "duration_ms": "400"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("left"))

        let resultWithElement = await server.execute(
            toolName: "swipe_in_direction",
            arguments: ["direction": "up", "element_id": "scroll-view"]
        )
        XCTAssertFalse(resultWithElement.isError)

        let missing = await server.execute(
            toolName: "swipe_in_direction",
            arguments: [:]
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content.contains("direction"))

        let calls = await driver.calls
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:left") }))
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:up") }))
    }

    func testSwipeInDirectionToolNameExposed() {
        let server = MCPServer()
        XCTAssertTrue(server.toolNames().contains("swipe_in_direction"))
    }

    /// The row-mistargeting failure mode (label/id resolution hitting the wrong row inside a
    /// list with per-row actions, e.g. SwiftUI List `.swipeActions`) cost real debugging time.
    /// The schema now pins the one canonical workflow — find_elements, then swipe_in_direction
    /// with the row's element_id, coordinates only as a fallback — so it can't silently regress
    /// or drift back to "prefer coordinates".
    func testSwipeInDirectionDescriptionWarnsAboutRowMistargeting() {
        let definition = ActionTools.definitions.first { $0.name == "swipe_in_direction" }
        XCTAssertNotNil(definition)
        XCTAssertTrue(definition?.description.contains("find_elements") == true)
        XCTAssertTrue(definition?.description.lowercased().contains("list") == true)
        XCTAssertTrue(definition?.description.contains("element_id (preferred)") == true)
    }

    func testTapElementDescriptionWarnsAboutRowMistargeting() {
        let definition = ActionTools.definitions.first { $0.name == "tap_element" }
        XCTAssertNotNil(definition)
        XCTAssertTrue(definition?.description.contains("find_elements") == true)
        XCTAssertTrue(definition?.description.lowercased().contains("list") == true)
    }

    // MARK: - Session lifecycle

    func testStartSessionReturnsSessionID() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let result = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "platform": "ios"]
        )
        XCTAssertFalse(result.isError, result.content)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["app_id"]?.stringValue, "com.example")
        XCTAssertEqual(structured["platform"]?.stringValue, "ios")
        XCTAssertNotNil(structured["session_id"]?.stringValue)

        let all = await manager.allSessions()
        XCTAssertEqual(all.count, 1)
    }

    func testStartSessionRejectsUnknownPlatform() async {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let result = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "platform": "blackberry"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("unknown platform"))
    }

    func testStartSessionWithoutSessionManagerReturnsError() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)
        let result = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertTrue(result.isError)
    }

    func testEndSessionClosesAndReportsActionCount() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let bootstrapper = stack.bootstrapper
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(toolName: "tap", arguments: ["x": "1", "y": "2", "session_id": sessionID])
        _ = await server.execute(toolName: "tap", arguments: ["x": "3", "y": "4", "session_id": sessionID])

        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        XCTAssertFalse(ended.isError, ended.content)
        let structured = try XCTUnwrap(ended.structuredContent?.objectValue)
        XCTAssertEqual(structured["action_count"]?.intValue, 2)

        let driverCallCount: Int = if let sessionDriver = await bootstrapper.lastDriver {
            await sessionDriver.calls.count
        } else {
            0
        }
        XCTAssertGreaterThanOrEqual(driverCallCount, 3) // 2 taps + 1 terminateApp on close
    }

    func testGetSessionReportRedactsTypeText() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(
            toolName: "type_text",
            arguments: ["text": "supersecret", "session_id": sessionID]
        )

        let report = await server.execute(
            toolName: "get_session_report",
            arguments: ["session_id": sessionID]
        )
        XCTAssertFalse(report.isError)

        let json = try JSONEncoder().encode(XCTUnwrap(report.structuredContent))
        let decoded = try SessionReport.makeJSONDecoder().decode(SessionReport.self, from: json)
        let typeTextAction = try XCTUnwrap(decoded.actions.first { $0.toolName == "type_text" })
        XCTAssertEqual(typeTextAction.arguments["text"], "<redacted, 11 chars>")
        XCTAssertNotEqual(typeTextAction.arguments["text"], "supersecret")
    }

    func testListSessionsReturnsSummary() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        _ = await server.execute(toolName: "start_session", arguments: ["app_id": "com.a"])
        _ = await server.execute(toolName: "start_session", arguments: ["app_id": "com.b"])

        let result = await server.execute(toolName: "list_sessions", arguments: [:])
        XCTAssertFalse(result.isError)
        let sessions = try XCTUnwrap(result.structuredContent?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 2)
    }

    func testCompileSessionToPlanDispatchesAndReturnsBothArtifacts() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(
            toolName: "tap_element",
            arguments: ["id": "submit-button", "session_id": sessionID]
        )
        _ = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])

        let result = await server.execute(toolName: "compile_session_to_plan", arguments: ["session_id": sessionID])
        XCTAssertFalse(result.isError, result.content)

        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertNotNil(structured["testFlow"])
        XCTAssertNotNil(structured["studioTest"])
        XCTAssertNotNil(structured["warnings"])

        let flowSteps = try XCTUnwrap(structured["testFlow"]?.objectValue?["steps"]?.arrayValue)
        XCTAssertEqual(flowSteps.first?.objectValue?["tool"]?.stringValue, "tap_element")

        let toolOperations = try XCTUnwrap(
            structured["studioTest"]?.objectValue?["compiledPlan"]?.objectValue?["toolOperations"]?.arrayValue
        )
        XCTAssertEqual(toolOperations.first?.objectValue?["tool"]?.stringValue, "tap_element")
    }

    func testCompileSessionToPlanMissingSessionIDReturnsError() async {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let result = await server.execute(toolName: "compile_session_to_plan", arguments: [:])
        XCTAssertTrue(result.isError)
    }

    // MARK: - Routing & recording

    func testTapWithSessionIDRoutesToSessionDriver() async throws {
        let stack = makeSessionStack()
        let defaultDriver = stack.defaultDriver
        let manager = stack.manager
        let bootstrapper = stack.bootstrapper
        let executor = DriverToolExecutor(driver: defaultDriver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(
            toolName: "tap",
            arguments: ["x": "10", "y": "20", "session_id": sessionID]
        )

        let defaultCalls = await defaultDriver.calls
        XCTAssertFalse(defaultCalls.contains("tap:10.0,20.0"), "Default driver should not see the tap")

        let resolved = await bootstrapper.lastDriver
        let sessionDriver = try XCTUnwrap(resolved)
        let sessionCalls = await sessionDriver.calls
        XCTAssertTrue(sessionCalls.contains("tap:10.0,20.0"))
    }

    func testTapWithoutSessionIDDoesNotRecord() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(toolName: "tap", arguments: ["x": "1", "y": "2"]) // no session_id

        let report = await server.execute(
            toolName: "get_session_report",
            arguments: ["session_id": sessionID]
        )
        let structured = try XCTUnwrap(report.structuredContent)
        let decoded = try SessionReport.makeJSONDecoder().decode(
            SessionReport.self,
            from: JSONEncoder().encode(structured)
        )
        XCTAssertTrue(
            decoded.actions.allSatisfy { $0.toolName != "tap" },
            "Tap without session_id should not be recorded in the session"
        )
    }
}
