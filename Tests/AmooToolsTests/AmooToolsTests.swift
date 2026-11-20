import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import TestSession
import XCTest

final class AmooToolsTests: XCTestCase {
    func testToolNamesAreExposed() {
        let server = ToolCatalog()
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
        let server = ToolCatalog()
        let defs = server.toolDefinitions()
        XCTAssertFalse(defs.isEmpty)

        let tap = defs.first(where: { $0.name == "tap" })
        XCTAssertNotNil(tap)
        XCTAssertEqual(tap?.required, ["x", "y"])
        XCTAssertEqual(tap?.properties.count, 6)
        XCTAssertNotNil(tap?.properties["session_id"], "session_id should be advertised on driver-routed tools")
        XCTAssertFalse(try XCTUnwrap(tap?.description.isEmpty))
    }

    func testEveryDriverRoutedToolAdvertisesSessionID() {
        let server = ToolCatalog()
        let defs = server.toolDefinitions()
        // Tools that don't route through resolveDriver: start_session and
        // list_sessions by design, and the companion-lifecycle tools, which act
        // on a platform/device rather than an open session. Everything else
        // should advertise it.
        let exempt: Set = [
            "start_session", "list_sessions", "companion_warm", "companion_status", "session_startup_status",
            "reset_companion",
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

        let tool = definition
        let inputSchema = tool.inputSchemaValue()

        XCTAssertEqual(tool.name, "tap")
        XCTAssertEqual(tool.title, "Tap")
        XCTAssertEqual(tool.description, "Tap a coordinate.")
        XCTAssertTrue(inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(inputSchema.description.contains("false"))
        XCTAssertTrue(inputSchema.description.contains("x"))
        XCTAssertTrue(inputSchema.description.contains("y"))
        XCTAssertNil(tool.outputSchemaValue())
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

        let inputSchema = definition.inputSchemaValue()

        XCTAssertTrue(inputSchema.description.contains("additionalProperties"))
        XCTAssertTrue(inputSchema.description.contains("false"))
        let outputSchema = try XCTUnwrap(definition.outputSchemaValue())
        XCTAssertTrue(outputSchema.description.contains("confidence"))
        XCTAssertTrue(outputSchema.description.contains("suggestedActions"))
        // Arguments are closed; results stay open so an added field cannot fail a validating client.
        XCTAssertFalse(outputSchema.description.contains("additionalProperties"))
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

        let outputSchema = try XCTUnwrap(definition.outputSchemaValue())
        let description = outputSchema.description
        XCTAssertTrue(description.contains("items"))
        XCTAssertTrue(description.contains("priority"))
        XCTAssertTrue(description.contains("action"))
        XCTAssertTrue(description.contains("string"))
    }

    func testWireByteCountCoversTextAndStructuredContent() {
        let structured: Value = .object(["suggestedActions": .array([.string("Tap Submit")])])
        let plain = ToolResult(content: "Suggested actions")
        let full = ToolResult(content: "Suggested actions", isError: true, structuredContent: structured)

        XCTAssertGreaterThan(plain.wireByteCount(), "Suggested actions".utf8.count)
        XCTAssertGreaterThan(full.wireByteCount(), plain.wireByteCount())
    }

    func testHealthPassThrough() {
        let server = ToolCatalog()
        XCTAssertEqual(server.health(), "ok")
    }

    func testExecuteWithoutDriverReturnsError() async {
        let server = ToolCatalog()
        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No tool executor"))
    }

    func testExecuteTapDelegatesToDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = ToolCatalog(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tapped"))

        let calls = await driver.calls
        XCTAssertEqual(calls, ["tap:10.0,20.0"])
    }

    func testExecuteDeviceLifecycle() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let app = scratch.url.appending(path: "App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = ToolCatalog(executor: executor)

        let boot = await server.execute(toolName: "device_boot", arguments: [:])
        XCTAssertFalse(boot.isError)

        let install = await server.execute(toolName: "device_install_app", arguments: ["path": app.path])
        XCTAssertFalse(install.isError, install.content)

        let launch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example"])
        XCTAssertFalse(launch.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["boot", "install:\(app.path)", "launch:com.example"])
    }

    func testExecuteValidatesArguments() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = ToolCatalog(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Missing required"))
    }

    func testExecuteUnknownToolReturnsError() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = ToolCatalog(executor: executor)

        let result = await server.execute(toolName: "nonexistent", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func testExecuteQueryTools() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = ToolCatalog(executor: executor)

        let context = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(context.isError)
        XCTAssertEqual(context.content, "Screen with 1 visible nodes")

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("root"))
    }

    func testCurrentAppReturnsDeclaredStructuredContent() async {
        let driver = MockDriver()
        let server = ToolCatalog(executor: DriverToolExecutor(driver: driver))

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
        let server = ToolCatalog(executor: executor)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down"])
        XCTAssertFalse(scroll.isError)

        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "hello"])
        XCTAssertFalse(typeText.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["scroll:down:300.0", "typeText:hello"])
    }
}
