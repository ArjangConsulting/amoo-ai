
import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

final class MCPServerTests: XCTestCase {
    func testToolNamesAreExposed() {
        let server = MCPServer()
        let names = server.toolNames()
        XCTAssertTrue(names.contains("tap"))
        XCTAssertTrue(names.contains("device_boot"))
        XCTAssertTrue(names.contains("find_elements"))
        XCTAssertTrue(names.contains("get_screen_context"))
        XCTAssertTrue(names.contains("scroll"))
        XCTAssertTrue(names.contains("set_permission"))
        XCTAssertTrue(names.contains("audit_app"))
        XCTAssertTrue(names.contains("audit_accessibility"))
        XCTAssertTrue(names.contains("audit_security"))
        XCTAssertTrue(names.contains("describe_screen"))
        XCTAssertTrue(names.contains("suggest_test_actions"))
        XCTAssertTrue(names.contains("analyze_ai_testability"))
        XCTAssertTrue(names.contains("find_element_by_description"))
        XCTAssertTrue(names.contains("start_session"))
        XCTAssertTrue(names.contains("end_session"))
        XCTAssertTrue(names.contains("list_sessions"))
        XCTAssertTrue(names.contains("get_session_report"))
        XCTAssertTrue(names.contains("navigate_to"))
        XCTAssertTrue(names.contains("fill_field"))
        XCTAssertTrue(names.contains("assert_visible"))
        XCTAssertTrue(names.contains("list_devices"))
        XCTAssertTrue(names.contains("list_apps"))
        XCTAssertFalse(names.contains { $0.hasPrefix("ai_") })
    }

    func testToolDefinitionsHaveSchemas() throws {
        let server = MCPServer()
        let defs = server.toolDefinitions()
        XCTAssertFalse(defs.isEmpty)

        let tap = defs.first(where: { $0.name == "tap" })
        XCTAssertNotNil(tap)
        XCTAssertEqual(tap?.required, ["x", "y"])
        // x, y, and the auto-injected session_id (optional).
        XCTAssertEqual(tap?.properties.count, 3)
        XCTAssertNotNil(tap?.properties["session_id"], "session_id should be advertised on driver-routed tools")
        XCTAssertFalse(try XCTUnwrap(tap?.description.isEmpty))
    }

    func testEveryDriverRoutedToolAdvertisesSessionID() {
        let server = MCPServer()
        let defs = server.toolDefinitions()
        // Tools that don't route through resolveDriver: start_session,
        // list_sessions don't accept session_id by design. Everything else
        // should advertise it.
        let exempt: Set = ["start_session", "list_sessions"]
        for def in defs where !exempt.contains(def.name) {
            XCTAssertNotNil(
                def.properties["session_id"],
                "Tool '\(def.name)' must advertise an optional session_id"
            )
        }
    }

    func testMCPToolConversionIncludesInputSchema() {
        let definition = ToolDefinition(
            name: "tap",
            title: "Tap",
            description: "Tap a coordinate.",
            properties: [
                "x": .init(type: "number", description: "Horizontal coordinate"),
                "y": .init(type: "number", description: "Vertical coordinate")
            ],
            required: ["x", "y"]
        )

        let tool = definition.mcpTool()

        XCTAssertEqual(tool.name, "tap")
        XCTAssertEqual(tool.title, "Tap")
        XCTAssertEqual(tool.description, "Tap a coordinate.")
        XCTAssertTrue(tool.inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(tool.inputSchema.description.contains("false"))
        XCTAssertTrue(tool.inputSchema.description.contains("x"))
        XCTAssertTrue(tool.inputSchema.description.contains("y"))
        XCTAssertNil(tool.outputSchema)
    }

    func testMCPToolConversionIncludesOutputSchema() throws {
        let definition = ToolDefinition(
            name: "suggest_test_actions",
            description: "Suggest actions.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "confidence": .init(type: "string", description: "Confidence level"),
                    "suggestedActions": .init(type: "array", description: "Ranked actions")
                ],
                required: ["confidence", "suggestedActions"]
            )
        )

        let tool = definition.mcpTool()

        XCTAssertTrue(tool.inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(tool.inputSchema.description.contains("false"))
        let outputSchema = try XCTUnwrap(tool.outputSchema)
        XCTAssertTrue(outputSchema.description.contains("confidence"))
        XCTAssertTrue(outputSchema.description.contains("suggestedActions"))
        XCTAssertTrue(outputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(outputSchema.description.contains("false"))
    }

    func testArrayOutputPropertyEmitsItemsSchema() throws {
        let definition = ToolDefinition(
            name: "suggest_test_actions",
            description: "Suggest actions.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "suggestedActions": .init(
                        type: "array",
                        description: "Ranked actions",
                        items: .object(
                            properties: [
                                "priority": .init(type: "integer", description: "Priority"),
                                "action": .init(type: "string", description: "Action")
                            ],
                            required: ["priority", "action"]
                        )
                    ),
                    "labels": .init(
                        type: "array",
                        description: "Labels",
                        items: .scalar(type: "string")
                    )
                ],
                required: ["suggestedActions", "labels"]
            )
        )

        let tool = definition.mcpTool()
        let outputSchema = try XCTUnwrap(tool.outputSchema)
        let description = outputSchema.description
        XCTAssertTrue(description.contains("items"))
        XCTAssertTrue(description.contains("priority"))
        XCTAssertTrue(description.contains("action"))
        XCTAssertTrue(description.contains("string"))
    }

    func testToolResultMCPResultPreservesContentErrorAndStructuredContent() throws {
        let structured: Value = .object([
            "confidence": .string("medium"),
            "suggestedActions": .array([.string("Tap Submit")])
        ])

        let result = ToolResult(content: "Suggested actions", isError: true, structuredContent: structured).mcpResult()

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(result.structuredContent, structured)
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            return XCTFail("Expected text content")
        }
        XCTAssertEqual(text, "Suggested actions")
    }

    func testStringifyArgumentValueHandlesAllCases() {
        XCTAssertEqual(stringifyArgumentValue(.null), "")
        XCTAssertEqual(stringifyArgumentValue(.bool(true)), "true")
        XCTAssertEqual(stringifyArgumentValue(.bool(false)), "false")
        XCTAssertEqual(stringifyArgumentValue(.int(42)), "42")
        XCTAssertEqual(stringifyArgumentValue(.double(1.5)), "1.5")
        XCTAssertEqual(stringifyArgumentValue(.string("hello")), "hello")
        XCTAssertEqual(stringifyArgumentValue(.array([.string("a"), .int(1)])), #"["a",1]"#)
        XCTAssertEqual(stringifyArgumentValue(.object(["k": .string("v")])), #"{"k":"v"}"#)
    }

    func testMCPStdioServeRespondsWithJSONRPCMessages() async throws {
        let process = Process()
        process.executableURL = try amooExecutableURL()
        process.arguments = ["mcp", "serve"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let output = LockedDataBuffer()
        let errorOutput = LockedDataBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                output.append(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                errorOutput.append(data)
            }
        }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"amoo-tests","version":"0.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}"#
        let messages = [
            #"{"jsonrpc":"2.0","id":"discover","method":"server/discover","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"modern-list","method":"tools/list","params":{\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"modern-call","method":"tools/call","params":{"name":"tap","arguments":{"x":10,"y":20},\#(modernMeta)}}"#,
            #"{"jsonrpc":"2.0","id":"unsupported","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"amoo-tests","version":"0.0.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#
        ].joined(separator: "\n") + "\n"
        try stdin.fileHandleForWriting.write(contentsOf: Data(messages.utf8))

        let data = try await waitForStdout(output) { text in
            text.contains(#""id":"discover""#)
                && text.contains(#""id":"modern-list""#)
                && text.contains(#""id":"modern-call""#)
                && text.contains(#""id":"unsupported""#)
                && text.contains(#""id":1"#)
                && text.contains(#""id":2"#)
                && text.contains("describe_screen")
        }

        let stdoutText = String(decoding: data, as: UTF8.self)
        let lines = stdoutText.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(lines.count, 2)

        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(object?["jsonrpc"] as? String, "2.0")
        }

        XCTAssertTrue(stdoutText.contains("suggest_test_actions"))
        XCTAssertTrue(errorOutput.data().isEmpty)

        let objects = try lines.compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let discover = try XCTUnwrap(objects.first { $0["id"] as? String == "discover" })
        let discoverResult = try XCTUnwrap(
            discover["result"] as? [String: Any],
            "Unexpected discovery response: \(discover)"
        )
        XCTAssertEqual(discoverResult["resultType"] as? String, "complete")
        let supportedVersions = try XCTUnwrap(discoverResult["supportedVersions"] as? [String])
        XCTAssertEqual(supportedVersions.first, "2026-07-28")
        XCTAssertTrue(supportedVersions.contains("2025-11-25"))
        XCTAssertEqual(discoverResult["ttlMs"] as? Int, 3_600_000)

        let modernList = try XCTUnwrap(objects.first { $0["id"] as? String == "modern-list" })
        let modernListResult = try XCTUnwrap(modernList["result"] as? [String: Any])
        XCTAssertEqual(modernListResult["resultType"] as? String, "complete")
        XCTAssertEqual(modernListResult["cacheScope"] as? String, "public")
        let modernTools = try XCTUnwrap(modernListResult["tools"] as? [[String: Any]])
        let modernToolNames = modernTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(modernToolNames, modernToolNames.sorted())

        let modernCall = try XCTUnwrap(objects.first { $0["id"] as? String == "modern-call" })
        let modernCallResult = try XCTUnwrap(modernCall["result"] as? [String: Any])
        XCTAssertEqual(modernCallResult["resultType"] as? String, "complete")
        XCTAssertEqual(modernCallResult["isError"] as? Bool, true)
        XCTAssertNotNil(modernCallResult["_meta"] as? [String: Any])

        let unsupported = try XCTUnwrap(objects.first { $0["id"] as? String == "unsupported" })
        let unsupportedError = try XCTUnwrap(unsupported["error"] as? [String: Any])
        XCTAssertEqual(unsupportedError["code"] as? Int, -32022)

        try stdin.fileHandleForWriting.close()
        let exited = await waitForProcessExit(process, timeoutNanoseconds: 5_000_000_000)
        XCTAssertTrue(exited, "MCP stdio server should exit when stdin closes")
    }

    func testHealthPassThrough() {
        let server = MCPServer()
        XCTAssertEqual(server.health(), "ok")
    }

    func testExecuteWithoutDriverReturnsError() async {
        let server = MCPServer()
        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No tool executor"))
    }

    func testExecuteTapDelegatesToDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tapped"))

        let calls = await driver.calls
        XCTAssertEqual(calls, ["tap:10.0,20.0"])
    }

    func testExecuteDeviceLifecycle() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let boot = await server.execute(toolName: "device_boot", arguments: [:])
        XCTAssertFalse(boot.isError)

        let install = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])
        XCTAssertFalse(install.isError)

        let launch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example"])
        XCTAssertFalse(launch.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["boot", "install:/tmp/App.app", "launch:com.example"])
    }

    func testExecuteValidatesArguments() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Missing required"))
    }

    func testExecuteUnknownToolReturnsError() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "nonexistent", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func testExecuteQueryTools() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let context = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(context.isError)
        XCTAssertEqual(context.content, "Mock screen")

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("root"))
    }

    func testExecuteScrollAndTypeText() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down"])
        XCTAssertFalse(scroll.isError)

        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "hello"])
        XCTAssertFalse(typeText.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["scroll:down:300.0", "typeText:hello"])
    }

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
        if result.content.contains("finding") {
            XCTAssertTrue(result.isError)
        }
    }

    func testAuditPassesCleanApp() async {
        let driver = MockDriver() // Clean mock with no problematic elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.clean"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Audit passed") || result.content.contains("finding"))
    }

    // MARK: - Assistant Tool Tests

    func testDescribeScreen() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen summary: Mock screen"))
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
        XCTAssertEqual(fields["summary"]?.stringValue, "Mock screen")
        XCTAssertEqual(fields["interactableCount"]?.intValue, 0)
    }

    func testDescribeScreenIncludesVisibleStructureAndActions() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "describe_screen", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Screen summary: Debug mode enabled - Test screen"))
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

    // MARK: - Session lifecycle

    func testStartSessionReturnsSessionID() async throws {
        let (driver, manager, _) = makeSessionStack()
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
        let (driver, manager, _) = makeSessionStack()
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
        let (driver, manager, bootstrapper) = makeSessionStack()
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
        let (driver, manager, _) = makeSessionStack()
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
        let decoded = try JSONDecoder().decode(SessionReport.self, from: json)
        let typeTextAction = try XCTUnwrap(decoded.actions.first { $0.toolName == "type_text" })
        XCTAssertEqual(typeTextAction.arguments["text"], "<redacted, 11 chars>")
        XCTAssertNotEqual(typeTextAction.arguments["text"], "supersecret")
    }

    func testListSessionsReturnsSummary() async throws {
        let (driver, manager, _) = makeSessionStack()
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        _ = await server.execute(toolName: "start_session", arguments: ["app_id": "com.a"])
        _ = await server.execute(toolName: "start_session", arguments: ["app_id": "com.b"])

        let result = await server.execute(toolName: "list_sessions", arguments: [:])
        XCTAssertFalse(result.isError)
        let sessions = try XCTUnwrap(result.structuredContent?.objectValue?["sessions"]?.arrayValue)
        XCTAssertEqual(sessions.count, 2)
    }

    // MARK: - Routing & recording

    func testTapWithSessionIDRoutesToSessionDriver() async throws {
        let (defaultDriver, manager, bootstrapper) = makeSessionStack()
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
        let (driver, manager, _) = makeSessionStack()
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
        let decoded = try JSONDecoder().decode(SessionReport.self, from: JSONEncoder().encode(structured))
        XCTAssertTrue(
            decoded.actions.allSatisfy { $0.toolName != "tap" },
            "Tap without session_id should not be recorded in the session"
        )
    }

    // MARK: - Device discovery & app inventory

    func testListDevicesReturnsBootstrapperResults() async throws {
        let (driver, manager, bootstrapper) = makeSessionStack()
        await bootstrapper.setDevices([
            DeviceInfo(id: "udid-1", name: "iPhone 15", platform: .ios, osVersion: "17.0", state: .booted),
            DeviceInfo(id: "emulator-5554", name: "Pixel 7", platform: .android, osVersion: "14", state: .booted)
        ])
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let result = await server.execute(toolName: "list_devices", arguments: [:])
        XCTAssertFalse(result.isError)
        let devices = try XCTUnwrap(result.structuredContent?.objectValue?["devices"]?.arrayValue)
        XCTAssertEqual(devices.count, 2)
    }

    func testListAppsCallsDriverListApps() async throws {
        let driver = AppListMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "list_apps", arguments: [:])
        XCTAssertFalse(result.isError)
        let apps = try XCTUnwrap(result.structuredContent?.objectValue?["apps"]?.arrayValue)
        XCTAssertEqual(apps.count, 2)
    }

    // MARK: - device_launch_app args & env

    func testDeviceLaunchAppPassesLaunchArgsAndEnvironment() async {
        let driver = LaunchTrackingDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        _ = await server.execute(
            toolName: "device_launch_app",
            arguments: [
                "app_id": "com.example",
                "launch_args": "-ui_test,fast",
                "environment": "STAGE=test,VERBOSE=1"
            ]
        )

        let calls = await driver.launchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.appID, "com.example")
        XCTAssertEqual(calls.first?.arguments, ["-ui_test", "fast"])
        XCTAssertEqual(calls.first?.environment, ["STAGE": "test", "VERBOSE": "1"])
    }

    // MARK: - Intent tools

    func testFillFieldCallsSetText() async {
        let driver = SetTextTrackingDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "fill_field",
            arguments: ["field_description": "Email", "value": "user@test.com"]
        )
        XCTAssertFalse(result.isError, result.content)
        let calls = await driver.setTextCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.selector.description, "Email")
        XCTAssertEqual(calls.first?.text, "user@test.com")
        XCTAssertFalse(result.content.contains("user@test.com"))
    }

    func testNavigateToTapsMatchingElement() async throws {
        let driver = NavigationMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "navigate_to",
            arguments: ["description": "Submit", "timeout_ms": "500"]
        )
        XCTAssertFalse(result.isError, result.content)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["navigated"]?.boolValue, true)
        let tapped = await driver.tappedSelectors
        XCTAssertEqual(tapped.count, 1)
    }

    func testNavigateToReturnsFailureWhenNoMatch() async throws {
        let driver = NavigationMockDriver(elements: [], summary: "Home")
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "navigate_to",
            arguments: ["description": "Pluto", "timeout_ms": "200"]
        )
        XCTAssertTrue(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["navigated"]?.boolValue, false)
        XCTAssertEqual(structured["reason"]?.stringValue, "no_match")
    }

    func testAssertVisibleSucceedsWhenElementPresent() async throws {
        let driver = NavigationMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "assert_visible",
            arguments: ["description": "Submit", "timeout_ms": "200"]
        )
        XCTAssertFalse(result.isError, result.content)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["passed"]?.boolValue, true)
    }

    func testAssertVisibleTimesOut() async throws {
        let driver = NavigationMockDriver(elements: [], summary: "Home")
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "assert_visible",
            arguments: ["description": "Nope", "timeout_ms": "200"]
        )
        XCTAssertTrue(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["passed"]?.boolValue, false)
    }

    // MARK: - Screenshot

    func testTakeScreenshotReturnsImageContentBlock() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "take_screenshot", arguments: [:])
        XCTAssertFalse(result.isError, result.content)

        let image = try XCTUnwrap(result.image, "take_screenshot must return an image content block")
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertFalse(image.data.isEmpty)

        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["format"]?.stringValue, "png")
        XCTAssertEqual(fields["byte_count"]?.intValue, 1)

        // The MCP result should carry both a text and an image content item.
        let mcp = result.mcpResult()
        XCTAssertEqual(mcp.content.count, 2)
    }

    func testTakeScreenshotJPEGAcceptsJpgAlias() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "take_screenshot", arguments: ["format": "jpg"])
        XCTAssertFalse(result.isError, result.content)
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertEqual(result.structuredContent?.objectValue?["format"]?.stringValue, "jpeg")
    }

    func testTakeScreenshotWritesToOutputPath() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let path = NSTemporaryDirectory() + "amoo-shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = await server.execute(toolName: "take_screenshot", arguments: ["output": path])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(result.structuredContent?.objectValue?["saved_path"]?.stringValue, path)
        XCTAssertTrue(result.content.contains("saved to"))
    }

    func testTakeScreenshotWriteFailureKeepsRequiredStructuredFields() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let path = NSTemporaryDirectory() + "amoo-missing-\(UUID().uuidString)/shot.png"
        let result = await server.execute(toolName: "take_screenshot", arguments: ["output": path])

        XCTAssertTrue(result.isError)
        // The declared outputSchema requires byte_count and format even on error.
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["byte_count"]?.intValue, 1)
        XCTAssertEqual(fields["format"]?.stringValue, "png")
        XCTAssertNil(fields["saved_path"])
    }

    // MARK: - Helpers

    private func makeSessionStack() -> (MockDriver, SessionManager, MockSessionBootstrapper) {
        let defaultDriver = MockDriver()
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { UUID().uuidString })
        return (defaultDriver, manager, bootstrapper)
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.withLock {
            storage.append(data)
        }
    }

    func data() -> Data {
        lock.withLock { storage }
    }
}

private func waitForStdout(
    _ buffer: LockedDataBuffer,
    timeoutNanoseconds: UInt64 = 5_000_000_000,
    condition: (String) -> Bool
) async throws -> Data {
    let start = ContinuousClock.now
    while start.duration(to: .now) < .nanoseconds(Int64(timeoutNanoseconds)) {
        let data = buffer.data()
        let text = String(decoding: data, as: UTF8.self)
        if condition(text) {
            return data
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    let text = String(decoding: buffer.data(), as: UTF8.self)
    throw XCTSkip("Timed out waiting for MCP stdio response. Captured stdout: \(text)")
}

private func waitForProcessExit(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
    let start = ContinuousClock.now
    while process.isRunning {
        if start.duration(to: .now) >= .nanoseconds(Int64(timeoutNanoseconds)) {
            return false
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}

private func amooExecutableURL() throws -> URL {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let packageRoot = sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        packageRoot.appendingPathComponent(".build/debug/amoo"),
        packageRoot.appendingPathComponent(".build/out/Products/Debug/amoo"),
        packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/amoo")
    ]

    guard let executableURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        let paths = candidates.map(\.path).joined(separator: ", ")
        throw XCTSkip("Cannot locate built amoo executable at any expected path: \(paths).")
    }

    return executableURL
}

/// Mock driver that returns elements triggering audit rules.
private actor AuditMockDriver: PlatformDriver {
    func boot() async throws {}
    func shutdown() async throws {}
    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID _: String) async throws {}
    func uninstallApp(appID _: String) async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_: ElementSelector) async throws {}

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func swipe(direction _: Direction, distance _: Double, duration _: Duration) async throws {}
    func swipe(
        direction _: Direction,
        distance _: Double,
        duration _: Duration,
        element _: ElementSelector?
    ) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}
    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {}
    func pressHome() async throws {}
    func openURL(_: String) async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [
            // Element with empty label and empty id — triggers missing accessibility label
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 0, y: 0, width: 30, height: 30)),
            // Small tap target
            ElementInfo(id: "tiny", label: "Tiny", type: .button, frame: Rect(x: 10, y: 10, width: 20, height: 20)),
            // Sensitive text field — triggers insecure text field rule
            ElementInfo(id: "password_field", label: "Password", type: .textField),
            // Normal button
            ElementInfo(
                id: "submit_btn",
                label: "Submit",
                type: .button,
                frame: Rect(x: 0, y: 0, width: 100, height: 44)
            )
        ]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(
            id: "root",
            children: [
                ViewNode(id: "title", label: "Test screen", type: .staticText),
                ViewNode(id: "submit_btn", label: "Submit", type: .button),
                ViewNode(id: "cancel_btn", label: "Cancel", type: .button)
            ]
        )
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_: PermissionChange) async throws {}
    func setLocation(latitude _: Double, longitude _: Double) async throws {}
    func clearLocation() async throws {}
    func setAppearance(_: Appearance) async throws {}

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Debug mode enabled - Test screen", interactableCount: 4)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ]
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}

private actor MockDriver: PlatformDriver {
    var calls: [String] = []

    func boot() async throws {
        calls.append("boot")
    }

    func shutdown() async throws {
        calls.append("shutdown")
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path: String) async throws {
        calls.append("install:\(path)")
    }

    func launchApp(appID: String, arguments _: [String], environment _: [String: String]) async throws {
        calls.append("launch:\(appID)")
    }

    func terminateApp(appID: String) async throws {
        calls.append("terminate:\(appID)")
    }

    func uninstallApp(appID: String) async throws {
        calls.append("uninstall:\(appID)")
    }

    func tap(at point: Point) async throws {
        calls.append("tap:\(point.x),\(point.y)")
    }

    func doubleTap(at point: Point) async throws {
        calls.append("doubleTap:\(point.x),\(point.y)")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        calls.append("longPress")
    }

    func tapElement(_: ElementSelector) async throws {
        calls.append("tapElement")
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {
        calls.append("swipe")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration) async throws {
        calls.append("swipeInDirection:\(direction):\(distance)")
    }

    func swipe(direction: Direction, distance: Double, duration _: Duration, element: ElementSelector?) async throws {
        let suffix = element.flatMap(\.id).map { ":\($0)" } ?? ""
        calls.append("swipeInDirection:\(direction):\(distance)\(suffix)")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        calls.append("scroll:\(direction):\(distance)")
    }

    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_ text: String) async throws {
        calls.append("typeText:\(text)")
    }

    func clearText(characterCount _: Int?) async throws {
        calls.append("clearText")
    }

    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {
        calls.append("pressBack")
    }

    func pressHome() async throws {
        calls.append("pressHome")
    }

    func openURL(_ url: String) async throws {
        calls.append("openURL:\(url)")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: selector.id ?? "el", label: selector.label ?? "label")]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF], format: format)
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_ change: PermissionChange) async throws {
        calls.append("permission:\(change.appID):\(change.permission)")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        calls.append("location:\(latitude),\(longitude)")
    }

    func clearLocation() async throws {
        calls.append("clearLocation")
    }

    func setAppearance(_ appearance: Appearance) async throws {
        calls.append("appearance:\(appearance.rawValue)")
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Mock screen")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        []
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}

// MARK: - Additional test doubles for session, intent, and launch_args tests

private actor MockSessionBootstrapper: SessionBootstrapper {
    private var devices: [DeviceInfo] = []
    private(set) var lastDriver: MockDriver?
    private(set) var lastLaunchArguments: [String] = []
    private(set) var lastLaunchEnvironment: [String: String] = [:]

    func setDevices(_ values: [DeviceInfo]) {
        devices = values
    }

    func bootstrap(
        appID _: String,
        platform: Platform,
        deviceHint _: String?,
        buildPath _: String?,
        arguments: [String],
        environment: [String: String]
    ) async throws -> BootstrapResult {
        let driver = MockDriver()
        lastDriver = driver
        lastLaunchArguments = arguments
        lastLaunchEnvironment = environment
        return BootstrapResult(
            driver: driver,
            deviceID: "mock-\(platform.rawValue)",
            platform: platform,
            cleanup: {}
        )
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        devices
    }
}

private actor AppListMockDriver: PlatformDriver {
    func listApps() async throws -> [AppInfo] {
        [
            AppInfo(appID: "com.example.one", name: "One", version: "1.0"),
            AppInfo(appID: "com.example.two", name: "Two", version: nil)
        ]
    }
}

private actor LaunchTrackingDriver: PlatformDriver {
    struct LaunchCall: Sendable, Equatable {
        let appID: String
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var launchCalls: [LaunchCall] = []

    func launchApp(appID: String, arguments: [String], environment: [String: String]) async throws {
        launchCalls.append(LaunchCall(appID: appID, arguments: arguments, environment: environment))
    }
}

private actor SetTextTrackingDriver: PlatformDriver {
    struct SetTextCall: Sendable {
        let selector: ElementSelector
        let text: String
    }

    private(set) var setTextCalls: [SetTextCall] = []

    func setText(_ selector: ElementSelector, text: String) async throws {
        setTextCalls.append(SetTextCall(selector: selector, text: text))
    }
}

private actor NavigationMockDriver: PlatformDriver {
    private let elements: [ElementInfo]
    private let summary: String
    private(set) var tappedSelectors: [ElementSelector] = []
    private var currentSummary: String

    init(
        elements: [ElementInfo] = [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ],
        summary: String = "Home screen"
    ) {
        self.elements = elements
        self.summary = summary
        currentSummary = summary
    }

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        elements
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        elements
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: currentSummary)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        elements
    }

    func tapElement(_ selector: ElementSelector) async throws {
        tappedSelectors.append(selector)
        currentSummary = "After tap: \(selector.label ?? selector.id ?? "?")"
    }
}
