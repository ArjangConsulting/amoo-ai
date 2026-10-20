import Foundation
@testable import StudioProtocol
import Testing

@Suite("Catalog console")
struct StudioCatalogConsoleTests {
    @Test("any console tool runs with the selected device's platform and returns structured output")
    func runsCatalogTools() async throws {
        let executor = ScriptedToolExecutor()
        let suggester = RecordingSuggester()
        let service = makeService(executor: executor, suggester: suggester)

        let result = try await service.execute(request("swipe_in_direction direction=up", platform: "android"))

        #expect(result.isError == false)
        #expect(result.tool == "swipe_in_direction")
        #expect(result.structuredContent == #"{"ok":true}"#)
        let call = try #require(await executor.calls.first)
        #expect(call.tool == "swipe_in_direction")
        #expect(call.arguments == ["direction": "up"])
        #expect(call.platform == "android")
        #expect(await suggester.invalidated == ["emulator-5554"])
    }

    @Test("read-only tools keep cached element suggestions")
    func readOnlyKeepsCache() async throws {
        let suggester = RecordingSuggester()
        let service = makeService(executor: ScriptedToolExecutor(), suggester: suggester)

        _ = try await service.execute(request("find_elements"))

        #expect(await suggester.invalidated.isEmpty)
    }

    @Test("a tool failure is a result with isError, not a protocol error")
    func toolFailure() async throws {
        let service = makeService(executor: ScriptedToolExecutor(failure: "No element matched id=missing"))

        let result = try await service.execute(request("tap_element id=missing"))

        #expect(result.isError == true)
        #expect(result.output.contains("No element matched"))
    }

    @Test("invalid lines are rejected with the first error diagnostic")
    func invalidLine() async {
        let service = makeService(executor: ScriptedToolExecutor())

        await #expect(throws: StudioAutomationError.self) {
            _ = try await service.execute(request("device_uninstall_app app_id=dev.app"))
        }
    }

    @Test("built-in commands still work with a catalog")
    func builtinsStillWork() async throws {
        let service = makeService(executor: ScriptedToolExecutor())

        let result = try await service.execute(request("Devices List"))

        #expect(result.output.contains("emulator-5554"))
    }

    @Test("element suggestions are requested only for selector values on a selected device")
    func suggestionGating() async {
        let suggester = RecordingSuggester(elements: [.init(id: "login", label: "Sign in", type: "button")])
        let service = makeService(executor: ScriptedToolExecutor(), suggester: suggester)

        let ids = await service.complete(.init(
            line: "tap_element id=",
            cursor: 15,
            selectedDeviceId: "sim-1",
            platform: "ios"
        ))
        _ = await service.complete(.init(
            line: "swipe_in_direction direction=",
            cursor: 29,
            selectedDeviceId: "sim-1",
            platform: "ios"
        ))
        _ = await service.complete(.init(line: "tap_element id=", cursor: 15))

        #expect(ids.items.map(\.label) == ["login"])
        #expect(await suggester.requests == 1)
    }

    @Test("a failing suggester still yields completion")
    func suggesterFailure() async {
        let service = makeService(executor: ScriptedToolExecutor(), suggester: RecordingSuggester(fails: true))

        let result = await service.complete(.init(
            line: "tap_element id=",
            cursor: 15,
            selectedDeviceId: "sim-1",
            platform: "ios"
        ))

        #expect(result.items.isEmpty)
        #expect(result.replaceStart == 15)
    }

    @Test("the handshake advertises catalog capabilities only when a catalog is configured")
    func capabilities() async throws {
        let withCatalog = StudioService(
            workspace: AutomationWorkspace(),
            automation: makeService(executor: ScriptedToolExecutor())
        )
        let without = StudioService(workspace: AutomationWorkspace())
        let handshake = Data(#"{"jsonrpc":"2.0","id":1,"method":"system.handshake"}"#.utf8)

        let enabled = try await capabilities(in: withCatalog.handle(handshake))
        let disabled = try await capabilities(in: without.handle(handshake))

        #expect(enabled.contains("tools.catalog"))
        #expect(enabled.contains("repl.complete"))
        #expect(!disabled.contains("tools.catalog"))
    }

    @Test("tools.catalog returns the catalog over the protocol")
    func catalogMethod() async throws {
        let service = StudioService(
            workspace: AutomationWorkspace(),
            automation: makeService(executor: ScriptedToolExecutor())
        )
        let response = await service.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools.catalog"}"#.utf8))
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])

        #expect(tools.map { $0["name"] as? String }.contains("tap_element"))
        #expect((result["builtins"] as? [[String: Any]])?.isEmpty == false)
    }

    @Test("a mutating command returns the settled screen with its geometry when asked")
    func capturesScreenshot() async throws {
        let executor = ScriptedToolExecutor()
        let service = makeService(executor: executor)

        let result = try await service.execute(request("swipe_in_direction direction=up", screenshot: true))

        let screenshot = try #require(result.screenshot)
        #expect(screenshot.path.hasSuffix(".png"))
        #expect(screenshot.widthPixels == 1179)
        #expect(screenshot.widthPoints == 393)
        #expect(screenshot.scale == 3)
        #expect(await executor.calls.last?.arguments == ["settle_timeout_ms": "1500"])
    }

    @Test("read-only commands and requests without the flag take no extra screenshot")
    func noScreenshot() async throws {
        let executor = ScriptedToolExecutor()
        let service = makeService(executor: executor)

        let readOnly = try await service.execute(request("find_elements", screenshot: true))
        let unasked = try await service.execute(request("swipe_in_direction direction=up"))

        #expect(readOnly.screenshot == nil)
        #expect(unasked.screenshot == nil)
        #expect(await executor.calls.map(\.tool) == ["find_elements", "swipe_in_direction"])
    }

    @Test("a failed command still shows the screen it left behind")
    func failureScreenshot() async throws {
        let service = makeService(executor: ScriptedToolExecutor(failure: "No element matched"))

        let result = try await service.execute(request("tap_element id=missing", screenshot: true))

        #expect(result.isError == true)
        #expect(result.screenshot != nil)
    }

    @Test("a failed screenshot leaves the command's result intact")
    func screenshotFailure() async throws {
        let service = makeService(executor: ScriptedToolExecutor(screenshotFails: true))

        let result = try await service.execute(request("swipe_in_direction direction=up", screenshot: true))

        #expect(result.isError == false)
        #expect(result.screenshot == nil)
        #expect(result.output == "done")
    }

    @Test("tap points come from tap_element's verified point or a coordinate tap's arguments")
    func gesturePoints() async throws {
        let service = makeService(executor: ScriptedToolExecutor(structured: #"{"tap_point":{"x":120.5,"y":64}}"#))

        let tapped = try await service.execute(request("tap_element id=login"))

        #expect(tapped.gesturePoint == StudioPoint(x: 120.5, y: 64))
        #expect(LiveStudioAutomationService.gesturePoint(
            tool: "tap",
            arguments: ["x": "10", "y": "20"],
            structuredContent: nil
        ) == StudioPoint(x: 10, y: 20))
        #expect(LiveStudioAutomationService.gesturePoint(
            tool: "swipe_in_direction",
            arguments: [:],
            structuredContent: nil
        ) == nil)
    }

    private func capabilities(in response: Data) throws -> [String] {
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(object["result"] as? [String: Any])
        return try #require(result["capabilities"] as? [String])
    }

    private func makeService(
        executor: ScriptedToolExecutor,
        suggester: RecordingSuggester = RecordingSuggester()
    ) -> LiveStudioAutomationService {
        LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor,
            toolCatalogProvider: FixedCatalog(),
            elementSuggester: suggester
        )
    }

    private func request(_ command: String, platform: String? = nil, screenshot: Bool? = nil) -> StudioReplRequest {
        .init(
            command: command,
            activeTest: authoredTest(),
            selectedDeviceId: "emulator-5554",
            selectedProviderId: nil,
            platform: platform,
            captureScreenshot: screenshot
        )
    }
}

private struct FixedCatalog: StudioToolCatalogProviding {
    func tools() -> [StudioToolSchema] {
        grammarTestCatalog.tools
    }
}

private actor ScriptedToolExecutor: StudioToolExecuting {
    struct Call: Equatable {
        let tool: String
        let arguments: [String: String]
        let platform: String
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private(set) var calls: [Call] = []
    private let failure: String?
    private let screenshotFails: Bool
    private let structured: String

    init(failure: String? = nil, screenshotFails: Bool = false, structured: String = #"{"ok":true}"#) {
        self.failure = failure
        self.screenshotFails = screenshotFails
        self.structured = structured
    }

    func execute(
        _ operation: StudioToolOperation,
        deviceId _: String,
        platform: String,
        appId _: String?
    ) throws -> StudioToolExecutionResult {
        calls.append(.init(tool: operation.tool, arguments: operation.arguments, platform: platform))
        if operation.tool == "take_screenshot" {
            if screenshotFails {
                throw Failure(description: "screen is locked")
            }
            return .init(
                output: "Captured",
                artifacts: ["/tmp/\(operation.id).png"],
                structuredContent: #"{"width_pixels":1179,"height_pixels":2556,"#
                    + #""width_points":393,"height_points":852,"scale":3}"#
            )
        }
        if let failure {
            throw Failure(description: failure)
        }
        return .init(output: "done", structuredContent: structured)
    }
}

private actor RecordingSuggester: StudioElementSuggesting {
    struct Failure: Error {}

    private let suggestions: [StudioElementSuggestion]
    private let fails: Bool
    private(set) var requests = 0
    private(set) var invalidated: [String] = []

    init(elements: [StudioElementSuggestion] = [], fails: Bool = false) {
        suggestions = elements
        self.fails = fails
    }

    func elements(deviceId _: String, platform _: String) throws -> [StudioElementSuggestion] {
        requests += 1
        if fails {
            throw Failure()
        }
        return suggestions
    }

    func invalidate(deviceId: String) {
        invalidated.append(deviceId)
    }
}
