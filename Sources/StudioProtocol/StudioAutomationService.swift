import Foundation

public struct StudioReplRequest: Codable, Sendable {
    public let command: String
    public let activeTest: StudioAuthoredTest
    public let selectedDeviceId: String?
    public let selectedProviderId: String?
    public init(command: String, activeTest: StudioAuthoredTest, selectedDeviceId: String?, selectedProviderId: String?) {
        self.command = command; self.activeTest = activeTest; self.selectedDeviceId = selectedDeviceId; self.selectedProviderId = selectedProviderId
    }
}

public struct StudioReplResult: Codable, Equatable, Sendable {
    public let output: String
    public init(output: String) { self.output = output }
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

public enum StudioReportStatus: String, Codable, Sendable { case passed = "Passed"; case failed = "Failed"; case cancelled = "Cancelled"; case running = "Running" }

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
    public init(reports: [StudioTestReport]) { self.reports = reports }
}

public protocol StudioAutomationServing: Sendable {
    func execute(_ request: StudioReplRequest) async throws -> StudioReplResult
    func run(_ request: StudioTestRunRequest) async throws -> StudioTestRunResult
    func reports() async -> StudioReportListResult
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
    case unsupportedCommand(String), destructiveCommand, invalidTest(String)
    public var description: String { switch self {
    case let .unsupportedCommand(command): "Unsupported Studio command: \(command). Run 'help' to list commands."
    case .destructiveCommand: "Destructive commands must use a confirmed Studio workflow."
    case let .invalidTest(reason): "Test validation failed: \(reason)"
    } }
}

public actor LiveStudioAutomationService: StudioAutomationServing {
    private let workspace: any StudioDeviceWorkspace
    private let toolExecutor: (any StudioToolExecuting)?
    private let reportsURL: URL?
    private var storedReports: [StudioTestReport]

    public init(
        workspace: any StudioDeviceWorkspace,
        reportsURL: URL? = LiveStudioAutomationService.defaultReportsURL(),
        toolExecutor: (any StudioToolExecuting)? = nil
    ) {
        self.workspace = workspace
        self.reportsURL = reportsURL
        self.toolExecutor = toolExecutor
        storedReports = reportsURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([StudioTestReport].self, from: $0) } ?? []
    }

    public func execute(_ request: StudioReplRequest) async throws -> StudioReplResult {
        let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.range(of: #"(^|\s)(reset|erase|delete|uninstall)(\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw StudioAutomationError.destructiveCommand
        }
        switch command.lowercased() {
        case "help":
            return .init(output: "help\ndevices list\ndevices inspect <id>\ntests validate\ntests run\nsessions list\nreports list\nproviders inspect <id>")
        case "devices list":
            let devices = await workspace.listDevices()
            let output = devices.isEmpty ? "No devices found." : devices.map { "[\($0.platform.rawValue)] \($0.name) (\($0.id)) — \($0.status.rawValue)" }.joined(separator: "\n")
            return .init(output: output)
        case "tests validate":
            try Self.validate(request.activeTest)
            return .init(output: "Test '\(request.activeTest.name)' is valid with \(request.activeTest.steps.count) step(s).")
        case "tests run":
            guard let deviceID = request.selectedDeviceId else { throw StudioAutomationError.invalidTest("Choose a device before running the test.") }
            let result = try await run(.init(test: request.activeTest, deviceId: deviceID, providerId: request.selectedProviderId))
            return .init(output: result.message)
        case "sessions list":
            return .init(output: storedReports.isEmpty ? "No sessions found." : storedReports.map { "Session report \($0.id) — \($0.testName)" }.joined(separator: "\n"))
        case "reports list":
            return .init(output: storedReports.isEmpty ? "No reports found." : storedReports.map { "[\($0.status.rawValue)] \($0.testName) — \($0.id)" }.joined(separator: "\n"))
        default:
            if command.lowercased().hasPrefix("devices inspect ") {
                let id = String(command.dropFirst("devices inspect ".count))
                guard let device = await workspace.listDevices().first(where: { $0.id == id }) else {
                    throw StudioAutomationError.unsupportedCommand(command)
                }
                return .init(output: "\(device.name)\nID: \(device.id)\nPlatform: \(device.platform.rawValue)\nOS: \(device.osVersion)\nStatus: \(device.status.rawValue)")
            }
            if command.lowercased().hasPrefix("providers inspect "), let providerID = request.selectedProviderId {
                return .init(output: "Selected provider profile: \(providerID). Secrets remain environment-only.")
            }
            throw StudioAutomationError.unsupportedCommand(command)
        }
    }

    public func run(_ request: StudioTestRunRequest) async throws -> StudioTestRunResult {
        try Self.validate(request.test)
        let started = Date()
        let reportID = UUID().uuidString
        let sessionID = UUID().uuidString
        let operations = request.test.compiledPlan?.operations ?? []
        let toolOperations = request.test.compiledPlan?.toolOperations ?? []
        var failures: [String] = []
        var artifacts: [String] = []
        if operations.isEmpty && toolOperations.isEmpty {
            failures.append("No compiled tool plan is available. Generate or attach a plan before execution.")
        } else if !toolOperations.isEmpty {
            guard let toolExecutor else {
                throw StudioAutomationError.invalidTest("Real device tool execution is unavailable in this Amoo build.")
            }
            for operation in toolOperations {
                do {
                    let result = try await toolExecutor.execute(
                        operation,
                        deviceId: request.deviceId,
                        platform: request.test.platform,
                        appId: request.test.requirements?.appId
                    )
                    artifacts.append(contentsOf: result.artifacts)
                } catch {
                    failures.append("\(operation.id) (\(operation.tool)): \(error)")
                    break
                }
            }
        } else {
            for operation in operations {
                if operation.lowercased() == "tests run" {
                    failures.append("tests run: A compiled plan cannot recursively execute itself.")
                    continue
                }
                do {
                    _ = try await execute(.init(command: operation, activeTest: request.test, selectedDeviceId: request.deviceId, selectedProviderId: request.providerId))
                } catch { failures.append("\(operation): \(error)") }
            }
        }
        let report = StudioTestReport(
            id: reportID,
            testName: request.test.name,
            status: failures.isEmpty ? .passed : .failed,
            startedAt: ISO8601DateFormatter().string(from: started),
            durationMillis: Int(Date().timeIntervalSince(started) * 1_000),
            deviceName: request.deviceId,
            summary: failures.isEmpty ? "Completed \(toolOperations.isEmpty ? operations.count : toolOperations.count) operation(s)." : failures.joined(separator: "\n"),
            artifacts: artifacts
        )
        storedReports.insert(report, at: 0)
        persistReports()
        return .init(message: report.summary, sessionId: sessionID, reportId: reportID)
    }

    public func reports() -> StudioReportListResult { .init(reports: storedReports) }

    private static func validate(_ test: StudioAuthoredTest) throws {
        guard test.formatVersion == 1 else { throw StudioAutomationError.invalidTest("Unsupported format version \(test.formatVersion).") }
        guard test.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw StudioAutomationError.invalidTest("A name is required.") }
        guard test.steps.isEmpty == false else { throw StudioAutomationError.invalidTest("At least one step is required.") }
        guard test.steps.allSatisfy({ $0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { throw StudioAutomationError.invalidTest("Every step requires an instruction.") }
    }

    private func persistReports() {
        guard let reportsURL, let data = try? JSONEncoder().encode(storedReports) else { return }
        try? FileManager.default.createDirectory(at: reportsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: reportsURL, options: .atomic)
    }

    public nonisolated static func defaultReportsURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Amoo/Studio/reports.json")
    }
}
