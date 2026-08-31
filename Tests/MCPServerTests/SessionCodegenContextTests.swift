import AmooCore
import Foundation
import MCP
@testable import MCPServer
import StudioProtocol
import TestSession
import XCTest

/// Part 1 through the MCP flow: an agent can supply an app-owned test context at session or
/// compile time (not only via a later `amoo generate test --context` CLI override), and it is
/// persisted so an `end_session` recompile keeps it.
extension MCPServerTests {
    private var contextJSON: String {
        """
        {
          "imports": ["AppTestSupport"],
          "baseClass": "AppUITestCase",
          "appFactory": "makeApp()",
          "harnessLaunchesApp": true,
          "helpers": [{ "name": "signIn", "callTemplate": "signIn()" }],
          "selectorExpressions": { "app.tab.home": "AppIDs.home.tab" }
        }
        """
    }

    func testCompileSessionToPlanFoldsInlineTestContextIntoThePlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-ctx-compile-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let stack = makeSessionStack(store: FileSessionStore(root: root))
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await server.execute(
            toolName: "tap_element",
            arguments: ["id": "app.tab.home", "session_id": sessionID]
        )

        let compiled = await server.execute(toolName: "compile_session_to_plan", arguments: [
            "session_id": sessionID,
            "test_name": "HomeFlow",
            "context_json": contextJSON
        ])
        XCTAssertFalse(compiled.isError, compiled.content)

        // Read the persisted plan.json — the artifact `amoo generate test --plan` consumes.
        let resolvedDirectory = await stack.manager.sessionDirectory(for: sessionID)
        let directory = try XCTUnwrap(resolvedDirectory)
        let plan = try JSONDecoder().decode(
            StudioAuthoredTest.self,
            from: Data(contentsOf: directory.appendingPathComponent("plan.json"))
        )
        XCTAssertEqual(plan.testContext?.baseClass, "AppUITestCase")
        XCTAssertEqual(plan.testContext?.appFactory, "makeApp()")
        XCTAssertEqual(plan.testContext?.harnessLaunchesApp, true)
        XCTAssertEqual(plan.testContext?.selectorExpressions["app.tab.home"], "AppIDs.home.tab")
        XCTAssertEqual(plan.testContext?.helpers.first?.name, "signIn")
    }

    /// The full schema documented in `docs/test-context.md` (the "complete XCUITest example"),
    /// supplied inline at `start_session`, survives to the persisted `plan.json` verbatim —
    /// including `harnessLaunchesApp` and an explicit `idLookupTemplate: null`.
    func testStartSessionPersistsTheDocumentedXCUITestContextSchema() async throws {
        let documented = """
        {
          "imports": ["MyUITestSupport"],
          "baseClass": "MyAppUITestCase",
          "appFactory": "makeTestApplication()",
          "harnessLaunchesApp": true,
          "helpers": [],
          "selectorExpressions": {},
          "idLookupTemplate": null
        }
        """
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-ctx-doc-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let stack = makeSessionStack(store: FileSessionStore(root: root))
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        let started = await server.execute(toolName: "start_session", arguments: [
            "app_id": "com.example",
            "test_name": "DocumentedContextFlow",
            "context_json": documented
        ])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await server.execute(toolName: "tap_element", arguments: ["id": "app.tab.home", "session_id": sessionID])
        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        let planPath = try XCTUnwrap(ended.structuredContent?.objectValue?["plan_path"]?.stringValue)

        let plan = try JSONDecoder().decode(
            StudioAuthoredTest.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath))
        )
        let context = try XCTUnwrap(plan.testContext)
        XCTAssertEqual(context.imports, ["MyUITestSupport"])
        XCTAssertEqual(context.baseClass, "MyAppUITestCase")
        XCTAssertEqual(context.appFactory, "makeTestApplication()")
        XCTAssertTrue(context.harnessLaunchesApp)
        XCTAssertTrue(context.helpers.isEmpty)
        XCTAssertTrue(context.selectorExpressions.isEmpty)
        XCTAssertNil(context.idLookupTemplate)
    }

    /// Part 1: `compile_session_to_plan` is an optional preview. Calling it explicitly while the
    /// session is open must not change the plan `end_session` writes, and no lifecycle call may
    /// appear as a compiled operation or leave an `excluded` warning.
    func testExplicitCompilePreviewDoesNotContaminateTheEndSessionPlan() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let stack = makeSessionStack(store: FileSessionStore(root: root))
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        let started = await server.execute(toolName: "start_session", arguments: [
            "app_id": "com.example", "test_name": "LifecycleFlow"
        ])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)

        _ = await server.execute(toolName: "tap_element", arguments: ["id": "app.tab.home", "session_id": sessionID])
        // Explicit mid-session preview.
        let preview = await server.execute(toolName: "compile_session_to_plan", arguments: ["session_id": sessionID])
        XCTAssertFalse(preview.isError, preview.content)
        _ = await server.execute(
            toolName: "assert_visible",
            arguments: ["contains_text": "Home", "session_id": sessionID]
        )

        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        let planPath = try XCTUnwrap(ended.structuredContent?.objectValue?["plan_path"]?.stringValue)
        let plan = try JSONDecoder().decode(
            StudioAuthoredTest.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath))
        )
        let compiled = try XCTUnwrap(plan.compiledPlan)
        let operationTools = (compiled.toolOperations ?? []).map(\.tool)
        for lifecycle in ["start_session", "end_session", "compile_session_to_plan", "get_session_report"] {
            XCTAssertFalse(operationTools.contains(lifecycle), "\(lifecycle) leaked into toolOperations")
        }
        XCTAssertTrue(compiled.excludedWarnings.isEmpty, "lifecycle call produced an excluded warning")
        // The recorder never wrote the preview call into history, so there is not even a
        // notApplicable warning for it.
        XCTAssertFalse((compiled.warnings ?? []).contains { $0.toolName == "compile_session_to_plan" })
        XCTAssertEqual(plan.name, "LifecycleFlow")
    }

    func testSessionTimeContextSurvivesEndSessionRecompile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-ctx-end-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let contextFile = root.appendingPathComponent("test-context.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try contextJSON.data(using: .utf8)?.write(to: contextFile)

        let stack = makeSessionStack(store: FileSessionStore(root: root))
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        // Context reference supplied once, at session start.
        let started = await server.execute(toolName: "start_session", arguments: [
            "app_id": "com.example",
            "test_name": "PersistedNameFlow",
            "context_path": contextFile.path
        ])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await server.execute(
            toolName: "tap_element",
            arguments: ["id": "app.tab.home", "session_id": sessionID]
        )

        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        XCTAssertFalse(ended.isError, ended.content)
        let planPath = try XCTUnwrap(ended.structuredContent?.objectValue?["plan_path"]?.stringValue)
        let plan = try JSONDecoder().decode(
            StudioAuthoredTest.self,
            from: Data(contentsOf: URL(fileURLWithPath: planPath))
        )
        XCTAssertEqual(plan.name, "PersistedNameFlow")
        XCTAssertEqual(plan.testContext?.baseClass, "AppUITestCase")
        XCTAssertEqual(plan.testContext?.selectorExpressions["app.tab.home"], "AppIDs.home.tab")
    }
}
