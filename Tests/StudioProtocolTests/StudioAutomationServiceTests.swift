import Foundation
import StudioProtocol
import Testing

struct StudioAutomationServiceTests {
    @Test("REPL lists devices through the shared workspace")
    func devicesList() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let result = try await service.execute(repl("devices list"))
        #expect(result.output.contains("Pixel"))
        #expect(result.output.contains("emulator-5554"))
    }

    @Test("destructive REPL commands require the confirmed workflow")
    func destructiveCommand() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        await #expect(throws: StudioAutomationError.self) { try await service.execute(repl("apps reset data")) }
    }

    @Test("compiled plans produce persisted report summaries")
    func testRun() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let test = authoredTest(plan: .init(compiler: "test", compilerVersion: "1", operations: ["devices list"]))
        let result = try await service.run(.init(test: test, deviceId: "emulator-5554", providerId: nil))
        let reports = await service.reports()

        #expect(result.reportId != nil)
        #expect(reports.reports.first?.status == .passed)
    }

    @Test("typed plans execute real tool operations in order")
    func typedTestRun() async throws {
        let executor = RecordingToolExecutor()
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [
                .init(id: "operation-1", tool: "tap_element", arguments: ["id": "sign-in"]),
                .init(id: "operation-2", tool: "assert_visible", arguments: ["id": "home"])
            ]
        )

        let result = try await service.run(.init(test: authoredTest(plan: plan), deviceId: "emulator-5554", providerId: nil))

        #expect(result.message == "Completed 2 operation(s).")
        #expect(await executor.operations() == ["tap_element", "assert_visible"])
    }

    @Test("REPL can run the active compiled test")
    func replTestRun() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let test = authoredTest(plan: .init(compiler: "test", compilerVersion: "1", operations: ["devices list"]))
        let request = StudioReplRequest(command: "tests run", activeTest: test, selectedDeviceId: "emulator-5554", selectedProviderId: nil)

        let result = try await service.execute(request)

        #expect(result.output.contains("Completed 1 operation"))
    }

    private func repl(_ command: String) -> StudioReplRequest {
        .init(command: command, activeTest: authoredTest(), selectedDeviceId: nil, selectedProviderId: nil)
    }

    private func authoredTest(plan: StudioCompiledPlan? = nil) -> StudioAuthoredTest {
        .init(formatVersion: 1, name: "Smoke", description: "", platform: "Android", steps: [.init(id: "step-1", instruction: "Inspect devices", expected: "A device is available")], compiledPlan: plan)
    }
}

private actor RecordingToolExecutor: StudioToolExecuting {
    private var recorded: [String] = []

    func execute(
        _ operation: StudioToolOperation,
        deviceId _: String,
        platform _: String,
        appId _: String?
    ) -> StudioToolExecutionResult {
        recorded.append(operation.tool)
        return .init(output: "ok")
    }

    func operations() -> [String] { recorded }
}

private struct AutomationWorkspace: StudioDeviceWorkspace {
    func listDevices() async -> [StudioDevice] { [.init(id: "emulator-5554", name: "Pixel", platform: .android, osVersion: "16", status: .running, physical: false)] }
    func startDevice(_: String) async -> StudioOperationResult { .init(message: "started", artifactPath: nil) }
    func createDevice(_: StudioCreateDeviceRequest) async -> StudioOperationResult { .init(message: "created", artifactPath: nil) }
    func buildInstallRun(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "built", artifactPath: nil) }
    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "installed", artifactPath: nil) }
    func resetData(_: StudioAppRequest) async -> StudioOperationResult { .init(message: "reset", artifactPath: nil) }
}
