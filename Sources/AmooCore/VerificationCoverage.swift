import Foundation

/// Required verification coverage; dispatch success is deliberately absent from the proof model.
public struct VerificationCoverage: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case passed, failed, blocked, untested, preconditionFailed
    }

    public struct Check: Codable, Sendable, Equatable {
        public let id: String
        public var outcome: Outcome
        public var reason: String
        public var evidence: [String]
    }

    public private(set) var checks: [Check]

    public init(checks: [String]) {
        self.checks = checks.map {
            Check(id: $0, outcome: .untested, reason: "No explicit assertion completed", evidence: [])
        }
    }

    public var status: String {
        if checks.contains(where: { $0.outcome == .failed }) {
            return "fail"
        }
        if !checks.isEmpty, checks.allSatisfy({ $0.outcome == .passed }) {
            return "pass"
        }
        return checks.contains(where: { $0.outcome == .passed }) ? "partial" : "blocked"
    }

    public var completedChecks: Int {
        checks.filter { $0.outcome == .passed || $0.outcome == .failed }.count
    }

    public mutating func record(id: String, outcome: Outcome, reason: String, evidence: [String]) {
        guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[index].outcome = outcome
        checks[index].reason = reason
        checks[index].evidence = evidence
    }
}

/// Measured host output and wall-clock costs, without estimates of model tokens.
public struct VerificationMetrics: Codable, Sendable, Equatable {
    public var clientCalls = 0
    public var operations = 0
    public var responseBytes = 0
    public var imageBytes = 0
    public var evidenceImageBytes = 0
    public var imageDimensions: [String] = []
    public var setupMilliseconds = 0
    public var recoveryMilliseconds = 0

    public init() {}
}
