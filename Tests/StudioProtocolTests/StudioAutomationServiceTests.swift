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

        let result = try await service.run(.init(
            test: authoredTest(plan: plan),
            deviceId: "emulator-5554",
            providerId: nil
        ))

        #expect(result.message == "Completed 2 operation(s).")
        #expect(await executor.operations() == ["tap_element", "assert_visible"])
    }

    @Test("REPL executes quoted mobile tool commands")
    func replToolCommand() async throws {
        let executor = RecordingToolExecutor()
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let request = StudioReplRequest(
            command: "tap_element label=\"Sign in\"",
            activeTest: authoredTest(),
            selectedDeviceId: "emulator-5554",
            selectedProviderId: nil
        )

        _ = try await service.execute(request)

        let operations = await executor.recordedOperations()
        #expect(operations.count == 1)
        #expect(operations.first?.tool == "tap_element")
        #expect(operations.first?.arguments == ["label": "Sign in"])
    }

    @Test("async runs expose progress and support cancellation")
    func asyncCancellation() async throws {
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: SlowToolExecutor()
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [.init(id: "operation-1", tool: "take_screenshot")]
        )

        let started = await service.start(.init(
            test: authoredTest(plan: plan),
            deviceId: "emulator-5554",
            providerId: nil
        ))
        let running = try await service.status(runId: started.runId)
        let cancelled = try await service.cancel(runId: started.runId)

        #expect(running.state == .running)
        #expect(running.totalOperations == 1)
        #expect(cancelled.state == .cancelled)
    }

    @Test("REPL can run the active compiled test")
    func replTestRun() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let test = authoredTest(plan: .init(compiler: "test", compilerVersion: "1", operations: ["devices list"]))
        let request = StudioReplRequest(
            command: "tests run",
            activeTest: test,
            selectedDeviceId: "emulator-5554",
            selectedProviderId: nil
        )

        let result = try await service.execute(request)

        #expect(result.output.contains("Completed 1 operation"))
    }

    @Test("REPL exposes discoverable help and inspection commands")
    func replDiscoveryCommands() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)

        let help = try await service.execute(repl("  help\n"))
        let device = try await service.execute(repl("devices inspect emulator-5554"))
        let provider = try await service.execute(.init(
            command: "providers inspect local",
            activeTest: authoredTest(),
            selectedDeviceId: nil,
            selectedProviderId: "local"
        ))
        let sessions = try await service.execute(repl("sessions list"))
        let reports = try await service.execute(repl("reports list"))

        #expect(help.output.contains("take_screenshot"))
        #expect(device.output.contains("Platform: Android"))
        #expect(provider.output.contains("local"))
        #expect(sessions.output == "No sessions found.")
        #expect(reports.output == "No reports found.")
    }

    @Test("REPL reports actionable errors for incomplete commands")
    func replCommandErrors() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)

        await #expect(throws: StudioAutomationError.self) {
            try await service.execute(repl("devices inspect missing"))
        }
        await #expect(throws: StudioAutomationError.self) {
            try await service.execute(repl("tests run"))
        }
        await #expect(throws: StudioAutomationError.self) {
            try await service.execute(repl("tap_element id=sign-in"))
        }
    }

    @Test("typed execution requires a tool executor and records failures")
    func typedExecutionFailures() async throws {
        let operation = StudioToolOperation(id: "operation-1", tool: "tap_element", arguments: ["id": "sign-in"])
        let plan = StudioCompiledPlan(compiler: "studio", compilerVersion: "1", toolOperations: [operation])
        let request = StudioTestRunRequest(test: authoredTest(plan: plan), deviceId: "emulator-5554", providerId: nil)
        let unavailable = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)

        await #expect(throws: StudioAutomationError.self) { try await unavailable.run(request) }

        let failing = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: FailingToolExecutor()
        )
        let result = try await failing.run(request)
        let reports = await failing.reports()

        #expect(result.message.contains("operation-1"))
        #expect(reports.reports.first?.status == .failed)
    }

    @Test("unknown asynchronous run identifiers are rejected")
    func unknownRun() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)

        await #expect(throws: StudioAutomationError.self) { try await service.status(runId: "missing") }
        await #expect(throws: StudioAutomationError.self) { try await service.cancel(runId: "missing") }
    }

    private func repl(_ command: String) -> StudioReplRequest {
        .init(command: command, activeTest: authoredTest(), selectedDeviceId: nil, selectedProviderId: nil)
    }

    private func authoredTest(plan: StudioCompiledPlan? = nil) -> StudioAuthoredTest {
        .init(
            formatVersion: 1,
            name: "Smoke",
            description: "",
            platform: "Android",
            steps: [.init(id: "step-1", instruction: "Inspect devices", expected: "A device is available")],
            compiledPlan: plan
        )
    }

    @Test("test validation rejects each malformed authored-test shape")
    func validationErrors() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let validStep = StudioAuthoredTest.Step(id: "step-1", instruction: "Tap", expected: "Done")
        let invalidTests = [
            StudioAuthoredTest(formatVersion: 2, name: "Test", description: "", platform: "iOS", steps: [validStep]),
            StudioAuthoredTest(formatVersion: 1, name: "  ", description: "", platform: "iOS", steps: [validStep]),
            StudioAuthoredTest(formatVersion: 1, name: "Test", description: "", platform: "iOS", steps: []),
            StudioAuthoredTest(
                formatVersion: 1,
                name: "Test",
                description: "",
                platform: "iOS",
                steps: [.init(id: "step-1", instruction: " ", expected: "Done")]
            )
        ]

        for test in invalidTests {
            await #expect(throws: StudioAutomationError.self) {
                try await service.run(.init(test: test, deviceId: "device", providerId: nil))
            }
        }
    }

    @Test("empty and recursive legacy plans produce failed reports")
    func invalidLegacyPlans() async throws {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let empty = authoredTest(plan: .init(compiler: "studio", compilerVersion: "1"))
        let recursive = authoredTest(
            plan: .init(compiler: "studio", compilerVersion: "1", operations: ["tests run", "unknown command"])
        )

        let emptyResult = try await service.run(.init(test: empty, deviceId: "device", providerId: nil))
        let recursiveResult = try await service.run(.init(test: recursive, deviceId: "device", providerId: nil))

        #expect(emptyResult.message.contains("No compiled tool plan"))
        #expect(recursiveResult.message.contains("cannot recursively execute"))
        #expect(recursiveResult.message.contains("Unsupported Studio command"))
    }

    @Test("completed asynchronous runs expose artifacts and final status")
    func asyncCompletion() async throws {
        let executor = RecordingToolExecutor(artifacts: ["/tmp/screenshot.png"])
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [.init(id: "operation-1", tool: "take_screenshot")]
        )
        let started = await service.start(
            .init(test: authoredTest(plan: plan), deviceId: "emulator-5554", providerId: nil)
        )

        var status = try await service.status(runId: started.runId)
        for _ in 0 ..< 100 where status.state == .running {
            try await Task.sleep(for: .milliseconds(10))
            status = try await service.status(runId: started.runId)
        }
        let report = await service.reports().reports.first

        #expect(status.state == .passed)
        #expect(status.currentOperation == 1)
        #expect(report?.artifacts == ["/tmp/screenshot.png"])
    }

    @Test("failed asynchronous runs reach a terminal status")
    func asyncFailure() async throws {
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: FailingToolExecutor()
        )
        let plan = StudioCompiledPlan(
            compiler: "studio",
            compilerVersion: "1",
            toolOperations: [.init(id: "operation-1", tool: "tap_element")]
        )
        let started = await service.start(.init(test: authoredTest(plan: plan), deviceId: "device", providerId: nil))

        var status = try await service.status(runId: started.runId)
        for _ in 0 ..< 100 where status.state == .running {
            try await Task.sleep(for: .milliseconds(10))
            status = try await service.status(runId: started.runId)
        }

        #expect(status.state == .failed)
        #expect(status.message.contains("operation-1"))
    }

    @Test("reports persist and reload from disk")
    func reportPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let reportURL = directory.appending(path: "reports.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: reportURL)
        let plan = StudioCompiledPlan(compiler: "test", compilerVersion: "1", operations: ["devices list"])

        _ = try await writer.run(.init(test: authoredTest(plan: plan), deviceId: "device", providerId: nil))
        let reader = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: reportURL)
        let reports = await reader.reports()

        #expect(reports.reports.count == 1)
        #expect(reports.reports.first?.testName == "Smoke")
        #expect(LiveStudioAutomationService.defaultReportsURL()?.lastPathComponent == "reports.json")
    }

    @Test("REPL tokenization supports single quotes and latest duplicate values")
    func replTokenization() async throws {
        let executor = RecordingToolExecutor()
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            toolExecutor: executor
        )
        let input = StudioReplRequest(
            command: "set_text id=old ignored id='email field' value='hello world'",
            activeTest: authoredTest(),
            selectedDeviceId: "device",
            selectedProviderId: nil
        )

        _ = try await service.execute(input)
        let operation = await executor.recordedOperations().first

        #expect(operation?.arguments["id"] == "email field")
        #expect(operation?.arguments["value"] == "hello world")
        #expect(operation?.arguments["ignored"] == nil)
    }
}

private struct SlowToolExecutor: StudioToolExecuting {
    func execute(
        _: StudioToolOperation,
        deviceId _: String,
        platform _: String,
        appId _: String?
    ) async throws -> StudioToolExecutionResult {
        try await Task.sleep(for: .seconds(5))
        return .init(output: "ok")
    }
}

private struct FailingToolExecutor: StudioToolExecuting {
    struct Failure: Error {}

    func execute(
        _: StudioToolOperation,
        deviceId _: String,
        platform _: String,
        appId _: String?
    ) throws -> StudioToolExecutionResult {
        throw Failure()
    }
}

private actor RecordingToolExecutor: StudioToolExecuting {
    private var recorded: [StudioToolOperation] = []
    private let artifacts: [String]

    init(artifacts: [String] = []) {
        self.artifacts = artifacts
    }

    func execute(
        _ operation: StudioToolOperation,
        deviceId _: String,
        platform _: String,
        appId _: String?
    ) -> StudioToolExecutionResult {
        recorded.append(operation)
        return .init(output: "ok", artifacts: artifacts)
    }

    func operations() -> [String] {
        recorded.map(\.tool)
    }

    func recordedOperations() -> [StudioToolOperation] {
        recorded
    }
}

private struct AutomationWorkspace: StudioDeviceWorkspace {
    func listDevices() async -> [StudioDevice] {
        [.init(
            id: "emulator-5554",
            name: "Pixel",
            platform: .android,
            osVersion: "16",
            status: .running,
            physical: false
        )]
    }

    func startDevice(_: String) async -> StudioOperationResult {
        .init(message: "started", artifactPath: nil)
    }

    func createDevice(_: StudioCreateDeviceRequest) async -> StudioOperationResult {
        .init(
            message: "created",
            artifactPath: nil
        )
    }

    func buildInstallRun(_: StudioAppRequest) async
        -> StudioOperationResult {
        .init(message: "built", artifactPath: nil)
    }

    func reinstallRun(_: StudioAppRequest) async -> StudioOperationResult {
        .init(
            message: "installed",
            artifactPath: nil
        )
    }

    func resetData(_: StudioAppRequest) async -> StudioOperationResult {
        .init(message: "reset", artifactPath: nil)
    }
}
