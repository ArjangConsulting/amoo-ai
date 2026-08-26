import AmooCore
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

    @Test("code export routes to the platform-specific emitter")
    func codeExport() async throws {
        let service = LiveStudioAutomationService(
            workspace: AutomationWorkspace(),
            reportsURL: nil,
            codeEmitters: .init(ios: StubEmitter(platform: "iOS"), android: StubEmitter(platform: "Android"))
        )
        let plan = StudioCompiledPlan(compiler: "ai", compilerVersion: "1", toolOperations: [
            .init(id: "op-1", tool: "tap_element", arguments: ["id": "sign-in"])
        ])
        let test = authoredTest(plan: plan)
        let result = try await service.export(.init(test: test))
        #expect(result.fileName == "AndroidTest.txt")
    }

    @Test("code export rejects platforms with no configured emitter")
    func codeExportUnavailable() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let test = authoredTest(plan: .init(compiler: "ai", compilerVersion: "1", toolOperations: []))
        await #expect(throws: StudioAutomationError.self) { try await service.export(.init(test: test)) }
    }

    private func repl(_ command: String) -> StudioReplRequest {
        .init(command: command, activeTest: authoredTest(), selectedDeviceId: nil, selectedProviderId: nil)
    }

    @Test("test validation rejects each malformed authored-test shape")
    func validationErrors() async {
        let service = LiveStudioAutomationService(workspace: AutomationWorkspace(), reportsURL: nil)
        let validStep = StudioAuthoredTest.Step(id: "step-1", instruction: "Tap", expected: "Done")
        let invalidTests = [
            StudioAuthoredTest(formatVersion: 2, name: "Test", description: "", platform: .ios, steps: [validStep]),
            StudioAuthoredTest(formatVersion: 1, name: "  ", description: "", platform: .ios, steps: [validStep]),
            StudioAuthoredTest(formatVersion: 1, name: "Test", description: "", platform: .ios, steps: []),
            StudioAuthoredTest(
                formatVersion: 1,
                name: "Test",
                description: "",
                platform: .ios,
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
}
