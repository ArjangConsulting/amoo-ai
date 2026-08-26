import Foundation

public struct StudioReplRequest: Codable, Sendable {
    public let command: String
    public let activeTest: StudioAuthoredTest
    public let selectedDeviceId: String?
    public let selectedProviderId: String?
    public init(
        command: String,
        activeTest: StudioAuthoredTest,
        selectedDeviceId: String?,
        selectedProviderId: String?
    ) {
        self.command = command; self.activeTest = activeTest; self.selectedDeviceId = selectedDeviceId; self
            .selectedProviderId = selectedProviderId
    }
}

public struct StudioReplResult: Codable, Equatable, Sendable {
    public let output: String
    public init(output: String) {
        self.output = output
    }
}

public struct StudioTestRunRequest: Codable, Sendable {
    public let test: StudioAuthoredTest
    public let deviceId: String
    public let providerId: String?
    public init(test: StudioAuthoredTest, deviceId: String, providerId: String?) {
        self.test = test; self.deviceId = deviceId; self.providerId = providerId
    }
}

public struct StudioTestRunResult: Codable, Equatable, Sendable {
    public let message: String
    public let sessionId: String?
    public let reportId: String?
    public init(message: String, sessionId: String?, reportId: String?) {
        self.message = message; self.sessionId = sessionId; self.reportId = reportId
    }
}

public struct StudioTestStartResult: Codable, Equatable, Sendable {
    public let runId: String
    public init(runId: String) {
        self.runId = runId
    }
}

public enum StudioTestRunState: String, Codable,
    Sendable { case running = "Running"; case passed = "Passed"; case failed = "Failed"; case cancelled = "Cancelled" }

public struct StudioTestRunStatus: Codable, Equatable, Sendable {
    public let runId: String
    public let state: StudioTestRunState
    public let currentOperation: Int
    public let totalOperations: Int
    public let message: String
    public let sessionId: String?
    public let reportId: String?
    public init(
        runId: String,
        state: StudioTestRunState,
        currentOperation: Int,
        totalOperations: Int,
        message: String,
        sessionId: String?,
        reportId: String?
    ) {
        self.runId = runId; self.state = state; self.currentOperation = currentOperation; self
            .totalOperations = totalOperations
        self.message = message; self.sessionId = sessionId; self.reportId = reportId
    }
}

public enum StudioReportStatus: String, Codable,
    Sendable { case passed = "Passed"; case failed = "Failed"; case cancelled = "Cancelled"; case running = "Running" }

public struct StudioTestReport: Codable, Equatable, Sendable {
    public let id: String
    public let testName: String
    public let status: StudioReportStatus
    public let startedAt: String
    public let durationMillis: Int?
    public let deviceName: String
    public let summary: String
    public let artifacts: [String]
}

public struct StudioReportListResult: Codable, Equatable, Sendable {
    public let reports: [StudioTestReport]
    public init(reports: [StudioTestReport]) {
        self.reports = reports
    }
}

public protocol StudioAutomationServing: Sendable {
    func execute(_ request: StudioReplRequest) async throws -> StudioReplResult
    func run(_ request: StudioTestRunRequest) async throws -> StudioTestRunResult
    func reports() async -> StudioReportListResult
    func start(_ request: StudioTestRunRequest) async -> StudioTestStartResult
    func status(runId: String) async throws -> StudioTestRunStatus
    func cancel(runId: String) async throws -> StudioTestRunStatus
    func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult
}

public extension StudioAutomationServing {
    func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult {
        throw StudioAutomationError.invalidTest("Code export is unavailable in this Amoo build.")
    }
}

public struct StudioToolExecutionResult: Equatable, Sendable {
    public let output: String
    public let artifacts: [String]
    public init(output: String, artifacts: [String] = []) {
        self.output = output; self.artifacts = artifacts
    }
}

public protocol StudioToolExecuting: Sendable {
    func execute(
        _ operation: StudioToolOperation,
        deviceId: String,
        platform: String,
        appId: String?
    ) async throws -> StudioToolExecutionResult
}

public enum StudioAutomationError: Error, CustomStringConvertible {
    case unsupportedCommand(String), destructiveCommand, invalidTest(String), runNotFound(String)
    public var description: String {
        switch self {
        case let .unsupportedCommand(command): "Unsupported Studio command: \(command). Run 'help' to list commands."
        case .destructiveCommand: "Destructive commands must use a confirmed Studio workflow."
        case let .invalidTest(reason): "Test validation failed: \(reason)"
        case let .runNotFound(id): "Test run not found: \(id)"
        }
    }
}

public actor LiveStudioAutomationService: StudioAutomationServing {
    private let workspace: any StudioDeviceWorkspace
    private let toolExecutor: (any StudioToolExecuting)?
    private let codeEmitters: StudioCodeEmitters
    private let reportsURL: URL?
    private var storedReports: [StudioTestReport]
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var runStatuses: [String: StudioTestRunStatus] = [:]

    public init(
        workspace: any StudioDeviceWorkspace,
        reportsURL: URL? = LiveStudioAutomationService.defaultReportsURL(),
        toolExecutor: (any StudioToolExecuting)? = nil,
        codeEmitters: StudioCodeEmitters = .init()
    ) {
        self.workspace = workspace
        self.reportsURL = reportsURL
        self.toolExecutor = toolExecutor
        self.codeEmitters = codeEmitters
        storedReports = reportsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(
            [StudioTestReport].self,
            from: $0
        ) } ?? []
    }

    public func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult {
        let toolkit = request.test.requirements?.uiToolkit ?? .view
        let emitter = codeEmitters.emitter(for: request.test.platform, toolkit: toolkit)
        guard let emitter else {
            throw StudioAutomationError.invalidTest(
                "Code export is unavailable for platform '\(request.test.platform.rawValue)' and toolkit '\(toolkit.rawValue)'."
            )
        }
        do {
            return try emitter.generate(request.test)
        } catch {
            throw StudioAutomationError.invalidTest("Code export failed: \(error)")
        }
    }

    public func execute(_ request: StudioReplRequest) async throws -> StudioReplResult {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.range(
            of: #"(^|\s)(reset|erase|delete|uninstall)(\s|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            throw StudioAutomationError.destructiveCommand
        }
        switch command.lowercased() {
        case "help":
            return .init(
                output: "help\ndevices list\ndevices inspect <id>\ntests validate\ntests run\nsessions list\nreports list\nproviders inspect <id>\ntap_element id=<id>|label=<label>\nset_text id=<id> value=<value>\nassert_visible id=<id>|label=<label>\ntake_screenshot"
            )
        case "devices list":
            let devices = await workspace.listDevices()
            let output = devices.isEmpty ? "No devices found." : devices
                .map { "[\($0.platform.rawValue)] \($0.name) (\($0.id)) — \($0.status.rawValue)" }
                .joined(separator: "\n")
            return .init(output: output)
        case "tests validate":
            try Self.validate(request.activeTest)
            return .init(
                output: "Test '\(request.activeTest.name)' is valid with \(request.activeTest.steps.count) step(s)."
            )
        case "tests run":
            guard let deviceID = request.selectedDeviceId
            else { throw StudioAutomationError.invalidTest("Choose a device before running the test.") }
            let result = try await run(.init(
                test: request.activeTest,
                deviceId: deviceID,
                providerId: request.selectedProviderId
            ))
            return .init(output: result.message)
        case "sessions list":
            return .init(output: storedReports.isEmpty ? "No sessions found." : storedReports
                .map { "Session report \($0.id) — \($0.testName)" }.joined(separator: "\n"))
        case "reports list":
            return .init(output: storedReports.isEmpty ? "No reports found." : storedReports
                .map { "[\($0.status.rawValue)] \($0.testName) — \($0.id)" }.joined(separator: "\n"))
        default:
            if command.lowercased().hasPrefix("devices inspect ") {
                let id = String(command.dropFirst("devices inspect ".count))
                guard let device = await workspace.listDevices().first(where: { $0.id == id }) else {
                    throw StudioAutomationError.unsupportedCommand(command)
                }
                return .init(
                    output: "\(device.name)\nID: \(device.id)\nPlatform: \(device.platform.rawValue)\nOS: \(device.osVersion)\nStatus: \(device.status.rawValue)"
                )
            }
            if command.lowercased().hasPrefix("providers inspect "), let providerID = request.selectedProviderId {
                return .init(output: "Selected provider profile: \(providerID). Secrets remain environment-only.")
            }
            if let operation = Self.parseToolOperation(command) {
                guard let deviceID = request.selectedDeviceId else {
                    throw StudioAutomationError.invalidTest("Choose a device before running mobile commands.")
                }
                guard let toolExecutor else {
                    throw StudioAutomationError
                        .invalidTest("Real device tool execution is unavailable in this Amoo build.")
                }
                let result = try await toolExecutor.execute(
                    operation,
                    deviceId: deviceID,
                    platform: request.activeTest.platform.rawValue,
                    appId: request.activeTest.requirements?.appId
                )
                return .init(output: result.output)
            }
            throw StudioAutomationError.unsupportedCommand(command)
        }
    }

    public func run(_ request: StudioTestRunRequest) async throws -> StudioTestRunResult {
        try await run(request, tracking: nil)
    }

    public func start(_ request: StudioTestRunRequest) -> StudioTestStartResult {
        let runID = UUID().uuidString
        let total = request.test.compiledPlan?.toolOperations?.count ?? request.test.compiledPlan?.operations?
            .count ?? 0
        runStatuses[runID] = .init(
            runId: runID,
            state: .running,
            currentOperation: 0,
            totalOperations: total,
            message: "Preparing test…",
            sessionId: nil,
            reportId: nil
        )
        runTasks[runID] = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await run(request, tracking: runID)
                await finish(runId: runID, result: result)
            } catch is CancellationError {
                await markCancelled(runId: runID)
            } catch {
                await markFailed(runId: runID, message: String(describing: error))
            }
        }
        return .init(runId: runID)
    }

    public func status(runId: String) throws -> StudioTestRunStatus {
        guard let status = runStatuses[runId] else { throw StudioAutomationError.runNotFound(runId) }
        return status
    }

    public func cancel(runId: String) throws -> StudioTestRunStatus {
        guard let status = runStatuses[runId] else { throw StudioAutomationError.runNotFound(runId) }
        runTasks[runId]?.cancel()
        let cancelled = StudioTestRunStatus(
            runId: runId,
            state: .cancelled,
            currentOperation: status.currentOperation,
            totalOperations: status.totalOperations,
            message: "Test run cancelled.",
            sessionId: status.sessionId,
            reportId: status.reportId
        )
        runStatuses[runId] = cancelled
        return cancelled
    }

    private func run(_ request: StudioTestRunRequest, tracking runID: String?) async throws -> StudioTestRunResult {
        try Self.validate(request.test)
        let started = Date()
        let reportID = UUID().uuidString
        let sessionID = UUID().uuidString
        let operations = request.test.compiledPlan?.operations ?? []
        let toolOperations = request.test.compiledPlan?.toolOperations ?? []
        var failures: [String] = []
        var artifacts: [String] = []
        if operations.isEmpty, toolOperations.isEmpty {
            failures.append("No compiled tool plan is available. Generate or attach a plan before execution.")
        } else if !toolOperations.isEmpty {
            guard let toolExecutor else {
                throw StudioAutomationError.invalidTest("Real device tool execution is unavailable in this Amoo build.")
            }
            for operation in toolOperations {
                try Task.checkCancellation()
                updateProgress(
                    runId: runID,
                    operation: operation,
                    current: (toolOperations.firstIndex(of: operation) ?? 0) + 1,
                    total: toolOperations.count
                )
                do {
                    let result = try await toolExecutor.execute(
                        operation,
                        deviceId: request.deviceId,
                        platform: request.test.platform.rawValue,
                        appId: request.test.requirements?.appId
                    )
                    artifacts.append(contentsOf: result.artifacts)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failures.append("\(operation.id) (\(operation.tool)): \(error)")
                    break
                }
            }
        } else {
            for operation in operations {
                try Task.checkCancellation()
                if operation.lowercased() == "tests run" {
                    failures.append("tests run: A compiled plan cannot recursively execute itself.")
                    continue
                }
                do {
                    _ = try await execute(.init(
                        command: operation,
                        activeTest: request.test,
                        selectedDeviceId: request.deviceId,
                        selectedProviderId: request.providerId
                    ))
                } catch { failures.append("\(operation): \(error)") }
            }
        }
        let report = StudioTestReport(
            id: reportID,
            testName: request.test.name,
            status: failures.isEmpty ? .passed : .failed,
            startedAt: ISO8601DateFormatter().string(from: started),
            durationMillis: Int(Date().timeIntervalSince(started) * 1000),
            deviceName: request.deviceId,
            summary: failures
                .isEmpty ?
                "Completed \(toolOperations.isEmpty ? operations.count : toolOperations.count) operation(s)." :
                failures.joined(separator: "\n"),
            artifacts: artifacts
        )
        storedReports.insert(report, at: 0)
        persistReports()
        return .init(message: report.summary, sessionId: sessionID, reportId: reportID)
    }

    private func updateProgress(runId: String?, operation: StudioToolOperation, current: Int, total: Int) {
        guard let runId else { return }
        runStatuses[runId] = .init(
            runId: runId,
            state: .running,
            currentOperation: current,
            totalOperations: total,
            message: "Running \(operation.tool)…",
            sessionId: nil,
            reportId: nil
        )
    }

    private func finish(runId: String, result: StudioTestRunResult) {
        let reportStatus = storedReports.first { $0.id == result.reportId }?.status
        runStatuses[runId] = .init(
            runId: runId,
            state: reportStatus == .passed ? .passed : .failed,
            currentOperation: runStatuses[runId]?.totalOperations ?? 0,
            totalOperations: runStatuses[runId]?.totalOperations ?? 0,
            message: result.message,
            sessionId: result.sessionId,
            reportId: result.reportId
        )
        runTasks[runId] = nil
    }

    private func markCancelled(runId: String) {
        guard runStatuses[runId]?.state == .running else { return }
        let previous = runStatuses[runId]!
        runStatuses[runId] = .init(
            runId: runId,
            state: .cancelled,
            currentOperation: previous.currentOperation,
            totalOperations: previous.totalOperations,
            message: "Test run cancelled.",
            sessionId: nil,
            reportId: nil
        )
        runTasks[runId] = nil
    }

    private func markFailed(runId: String, message: String) {
        let previous = runStatuses[runId]
        runStatuses[runId] = .init(
            runId: runId,
            state: .failed,
            currentOperation: previous?.currentOperation ?? 0,
            totalOperations: previous?.totalOperations ?? 0,
            message: message,
            sessionId: nil,
            reportId: nil
        )
        runTasks[runId] = nil
    }

    public func reports() -> StudioReportListResult {
        .init(reports: storedReports)
    }

    private static func validate(_ test: StudioAuthoredTest) throws {
        guard test.formatVersion == 1
        else { throw StudioAutomationError.invalidTest("Unsupported format version \(test.formatVersion).") }
        guard test.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { throw StudioAutomationError.invalidTest("A name is required.") }
        guard test.steps.isEmpty == false
        else { throw StudioAutomationError.invalidTest("At least one step is required.") }
        guard test.steps
            .allSatisfy({ $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false })
        else { throw StudioAutomationError.invalidTest("Every step requires an instruction.") }
    }

    private static let studioTools: Set<String> = [
        "tap_element", "set_text", "type_text", "swipe_in_direction", "wait_for_element",
        "assert_visible", "assert_not_visible", "assert_text", "take_screenshot", "press_back"
    ]

    private static func parseToolOperation(_ command: String) -> StudioToolOperation? {
        let tokens = tokenize(command)
        guard let tool = tokens.first, studioTools.contains(tool) else { return nil }
        let pairs: [(String, String)] = tokens.dropFirst().compactMap { token in
            guard let separator = token.firstIndex(of: "=") else { return nil }
            return (String(token[..<separator]), String(token[token.index(after: separator)...]))
        }
        let arguments = Dictionary(pairs, uniquingKeysWith: { _, latest in latest })
        return .init(id: "repl-\(UUID().uuidString)", tool: tool, arguments: arguments)
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        for character in command {
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    token.append(character)
                }
            } else if character.isWhitespace, quote == nil {
                if !token.isEmpty {
                    tokens.append(token); token = ""
                }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty {
            tokens.append(token)
        }
        return tokens
    }

    private func persistReports() {
        guard let reportsURL, let data = try? JSONEncoder().encode(storedReports) else { return }
        try? FileManager.default.createDirectory(
            at: reportsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: reportsURL, options: .atomic)
    }

    nonisolated public static func defaultReportsURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Amoo/Studio/reports.json")
    }
}
