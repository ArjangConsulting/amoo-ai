import AmooCore
import Foundation
import StudioProtocol

// Shared stubs for the StudioAutomationService suites. Internal rather than file-private so the
// suites can be split across files without duplicating them.

struct SlowToolExecutor: StudioToolExecuting {
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

struct FailingToolExecutor: StudioToolExecuting {
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

actor RecordingToolExecutor: StudioToolExecuting {
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

struct AutomationWorkspace: StudioDeviceWorkspace {
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

struct StubEmitter: StudioCodeEmitting {
    let platform: String
    func generate(_: StudioAuthoredTest) throws -> StudioTestExportResult {
        .init(fileName: "\(platform)Test.txt", source: "// generated for \(platform)")
    }
}

/// The minimal valid authored test both suites build their scenarios from.
func authoredTest(plan: StudioCompiledPlan? = nil) -> StudioAuthoredTest {
    .init(
        formatVersion: 1,
        name: "Smoke",
        description: "",
        platform: .android,
        steps: [.init(id: "step-1", instruction: "Inspect devices", expected: "A device is available")],
        compiledPlan: plan
    )
}
