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
        XCTAssertTrue(names.contains("assert_enabled"))
        XCTAssertTrue(names.contains("assert_absent"))
        XCTAssertTrue(names.contains("assert_value"))
        XCTAssertTrue(names.contains("assert_screen_changed"))
        XCTAssertTrue(names.contains("set_text"))
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
        // x, y, unit, and the auto-injected session_id (optional).
        XCTAssertEqual(tap?.properties.count, 4)
        XCTAssertNotNil(tap?.properties["session_id"], "session_id should be advertised on driver-routed tools")
        XCTAssertFalse(try XCTUnwrap(tap?.description.isEmpty))
    }

    func testEveryDriverRoutedToolAdvertisesSessionID() {
        let server = MCPServer()
        let defs = server.toolDefinitions()
        // Tools that don't route through resolveDriver: start_session and
        // list_sessions by design, and the companion-lifecycle tools, which act
        // on a platform/device rather than an open session. Everything else
        // should advertise it.
        let exempt: Set = [
            "start_session", "list_sessions", "companion_warm", "companion_status",
            "webview_eval", "webview_dom"
        ]
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
        XCTAssertEqual(context.content, "Screen with 1 visible nodes")

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("root"))
    }

    func testCurrentAppReturnsDeclaredStructuredContent() async {
        let driver = MockDriver()
        let server = MCPServer(executor: DriverToolExecutor(driver: driver))

        let result = await server.execute(toolName: "current_app", arguments: [:])

        XCTAssertFalse(result.isError)
        XCTAssertEqual(
            result.structuredContent,
            .object([
                "bundle_id": .string("com.example.frontmost"),
                "target_bundle_id": .string("com.example.target")
            ])
        )
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
}
