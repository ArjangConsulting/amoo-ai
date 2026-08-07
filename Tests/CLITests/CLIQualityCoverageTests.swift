@testable import CLI
import Foundation
import ProcessRunner
import Testing

struct CLIQualityCoverageTests {
    @Test("Android preflight reports command success")
    func androidPreflightSuccess() async throws {
        let runner = PreflightProcessRunner(results: [
            .success(.init(exitCode: 0, stdout: "Android Debug Bridge", stderr: ""))
        ])

        let report = await DefaultPreflightChecker(processRunner: runner).run(platform: .android)

        #expect(report.platform == .android)
        #expect(!report.hasFailures)
        let check = try #require(report.checks.first)
        #expect(check.id == "android.adb")
        #expect(check.status == .pass)
        #expect(check.message.contains("adb version"))
        #expect(await runner.recordedCommands().count == 1)
    }

    @Test("Android preflight uses stderr for command failures")
    func androidPreflightFailure() async throws {
        let runner = PreflightProcessRunner(results: [
            .success(.init(exitCode: 7, stdout: "ignored", stderr: "adb unavailable\n"))
        ])

        let report = await DefaultPreflightChecker(processRunner: runner).run(platform: .android)

        #expect(report.hasFailures)
        let check = try #require(report.checks.first)
        #expect(check.status == .fail)
        #expect(check.message == "Exit 7: adb unavailable")
        #expect(check.remediation.contains("platform-tools"))
    }

    @Test("Android preflight reports execution errors")
    func androidPreflightExecutionError() async throws {
        let runner = PreflightProcessRunner(results: [.failure(PreflightTestError.failed)])

        let report = await DefaultPreflightChecker(processRunner: runner).run(platform: .android)

        let check = try #require(report.checks.first)
        #expect(check.status == .fail)
        #expect(check.message.contains("Execution failed"))
    }

    @Test("iOS preflight distinguishes required tools from optional device tools")
    func iOSPreflightFailurePolicy() async {
        let runner = PreflightProcessRunner(results: [
            .success(.init(exitCode: 1, stdout: "", stderr: "no Xcode")),
            .failure(PreflightTestError.failed),
            .failure(PreflightTestError.failed),
            .success(.init(exitCode: 1, stdout: "not found", stderr: ""))
        ])

        let report = await DefaultPreflightChecker(processRunner: runner).run(platform: .iOS)

        #expect(report.checks.map(\.id) == [
            "ios.xcode-select", "ios.simctl", "ios.devicectl", "ios.iproxy"
        ])
        #expect(report.checks.map(\.status) == [.fail, .fail, .warn, .warn])
        #expect(report.hasFailures)
    }

    @Test("All-platform preflight aggregates successful checks")
    func allPlatformPreflight() async {
        let success = Result<ProcessResult, any Error>.success(
            .init(exitCode: 0, stdout: "available", stderr: "")
        )
        let runner = PreflightProcessRunner(results: Array(repeating: success, count: 5))

        let report = await DefaultPreflightChecker(processRunner: runner).run(platform: .all)

        #expect(report.checks.count == 5)
        #expect(report.checks.last?.id == "android.adb")
        #expect(report.checks.allSatisfy { $0.status == .pass })
        #expect(!report.hasFailures)
    }

    @Test("Preflight rendering includes status and remediation")
    func preflightRendering() {
        let report = PreflightReport(platform: .iOS, checks: [
            .init(id: "pass", status: .pass, message: "ready", remediation: "unused"),
            .init(id: "warn", status: .warn, message: "optional", remediation: "install optional tool"),
            .init(id: "fail", status: .fail, message: "missing", remediation: "install required tool")
        ])

        let output = renderPreflightReport(report)

        #expect(output.contains("preflight"))
        #expect(output.contains("[PASS] pass - ready"))
        #expect(output.contains("[WARN] warn - optional"))
        #expect(output.contains("[FAIL] fail - missing"))
        #expect(output.contains("install optional tool"))
        #expect(output.contains("install required tool"))
        #expect(!output.contains("unused"))
    }

    @Test("Chat options use documented defaults")
    func chatOptionDefaults() throws {
        let options = try #require(parseChatCommandOptions(args: []).success)

        #expect(options.model == "qwen3.6:latest")
        #expect(options.platform == .ios)
        #expect(options.port == nil)
        #expect(options.deviceID == nil)
        #expect(options.ollamaHost == "127.0.0.1")
        #expect(options.ollamaPort == 11434)
        #expect(!options.noCompanion)
    }

    @Test("Chat options parse every supported override")
    func chatOptionOverrides() throws {
        let result = parseChatCommandOptions(args: [
            "-m", "gemma3", "--platform", "ANDROID", "--port", "23000",
            "--device", "emulator-5554", "--ollama-host", "localhost",
            "--ollama-port", "11435", "--no-companion"
        ])
        let options = try #require(result.success)

        #expect(options.model == "gemma3")
        #expect(options.platform == .android)
        #expect(options.port == 23000)
        #expect(options.deviceID == "emulator-5554")
        #expect(options.ollamaHost == "localhost")
        #expect(options.ollamaPort == 11435)
        #expect(options.noCompanion)
    }

    @Test(
        "Chat options reject invalid arguments",
        arguments: [
            (["--model"], "--model requires a value"),
            (["--platform"], "--platform requires a value"),
            (["--platform", "web"], "Invalid platform 'web'"),
            (["--port", "abc"], "--port requires an integer value"),
            (["--device"], "--device requires a value"),
            (["--ollama-host"], "--ollama-host requires a value"),
            (["--ollama-port", "abc"], "--ollama-port requires an integer value"),
            (["--unknown"], "Unknown option: --unknown")
        ]
    )
    func invalidChatOptions(arguments: [String], expectedMessage: String) throws {
        let error = try #require(parseChatCommandOptions(args: arguments).failure)
        #expect(error.description.contains(expectedMessage))
    }
}

private enum PreflightTestError: Error {
    case failed
}

private actor PreflightProcessRunner: ProcessRunner {
    private var results: [Result<ProcessResult, any Error>]
    private var commands: [[String]] = []

    init(results: [Result<ProcessResult, any Error>]) {
        self.results = results
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        commands.append(arguments)
        guard !results.isEmpty else {
            throw PreflightTestError.failed
        }
        return try results.removeFirst().get()
    }

    func recordedCommands() -> [[String]] {
        commands
    }
}

private extension Result {
    var success: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
