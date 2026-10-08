import Foundation

/// Compact subagent contract. Raw observations belong in local evidence files, not the parent transcript.
public struct AgentRunReport: Codable, Sendable {
    public struct Assertion: Codable, Sendable {
        public var check: String
        public var outcome: String
        public var evidence: [String]
    }

    public struct Coverage: Codable, Sendable {
        public var requested: [String]
        public var evaluated: [String]
        public var notEvaluated: [String: String]
        public var truncated: Bool
    }

    public let schemaVersion: Int
    public let runID: String
    public let status: String
    public let execution: String
    public let verdict: String
    public let cleanup: String
    public let summary: String
    public let provenance: [String: String]
    public let assertions: [Assertion]
    public let coverage: Coverage
    public let artifacts: [AgentEvidenceArtifact]

    // Keep the linear contract checks together so reviewers can audit every acceptance condition.
    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Checks internal consistency, mandatory caller scope and sealed evidence content.
    public func validationErrors(expectedRunID: String? = nil, requestedChecks: [String]? = nil) -> [String] {
        var errors: [String] = []
        if schemaVersion != 2 {
            errors.append("Unsupported schemaVersion")
        }
        if expectedRunID == nil || requestedChecks == nil {
            errors.append("Acceptance requires the caller's original run ID and requested checks")
        }
        if UUID(uuidString: runID) == nil || expectedRunID.map({ $0 != runID }) == true {
            errors.append("runID must be a UUID matching the caller's run")
        }
        if !["pass", "fail", "blocked", "done"].contains(status) {
            errors.append("Invalid status")
        }
        if !["succeeded", "failed", "blocked"].contains(execution) {
            errors.append("Invalid execution")
        }
        if !["pass", "fail", "notAssessed"].contains(verdict) {
            errors.append("Invalid verdict")
        }
        if !["released", "restored", "notRequired", "failed", "unknown"].contains(cleanup) {
            errors.append("Invalid cleanup")
        }
        if summary.isEmpty || summary.count > 800 || assertions.count > 128 || artifacts.count > 32 {
            errors.append("Report exceeds compact bounds or has an empty summary")
        }
        let provenanceKeys = ["app_id", "app_build", "device_id", "device_os", "locale", "host_binary", "host_version"]
        for key in provenanceKeys where provenance[key]?.isEmpty != false {
            errors.append("Missing provenance: \(key); use unknown when unavailable")
        }
        if coverage.requested.count > 128 || provenance.count > 24
            || provenance.values.contains(where: { $0.count > 1000 })
            || coverage.requested
            .contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 120 })
            || coverage.notEvaluated.values.contains(where: { $0.count > 400 }) {
            errors.append("Coverage or provenance exceeds compact bounds")
        }
        if let binary = provenance["host_binary"], !binary.hasPrefix("/"), binary != "unknown" {
            errors.append("host_binary must be an absolute path or unknown")
        }
        let requested = Set(coverage.requested)
        let evaluated = Set(coverage.evaluated)
        let unchecked = Set(coverage.notEvaluated.keys)
        let checks = assertions.map(\.check)
        if requested.count != coverage.requested.count || evaluated.count != coverage.evaluated.count
            || Set(checks).count != checks.count {
            errors.append("Duplicate check IDs")
        }
        if requestedChecks.map({ Set($0) != requested }) == true {
            errors.append("Coverage differs from the caller's requested checks")
        }
        if !evaluated.isSubset(of: requested) || !unchecked.isSubset(of: requested)
            || !evaluated.isDisjoint(with: unchecked) || evaluated.union(unchecked) != requested
            || coverage.notEvaluated.values.contains(where: \.isEmpty) {
            errors.append("Every requested check needs evaluated coverage or a not-evaluated reason")
        }
        if Set(checks) != evaluated || assertions.contains(where: { !["pass", "fail"].contains($0.outcome) }) {
            errors.append("Each evaluated check requires exactly one pass/fail assertion")
        }
        for assertion in assertions where assertion.evidence.isEmpty || assertion.evidence.count > 8 {
            errors.append("Assertion \(assertion.check) requires 1...8 evidence references")
        }
        errors += evidenceErrors(requested: requested)
        if status == "pass" || verdict == "pass" {
            if provenanceKeys.contains(where: {
                let value = provenance[$0]?.lowercased() ?? "unknown"
                return value == "unknown" || value.hasPrefix("unavailable")
            }) || !Self.isSHA256(provenance["host_sha256"] ?? "") {
                errors.append("Pass requires identified app/device/locale and a host binary SHA-256")
            }
            if status != "pass" || verdict != "pass" || execution != "succeeded"
                || !["released", "restored", "notRequired"].contains(cleanup)
                || requested.isEmpty || evaluated != requested || !unchecked.isEmpty || coverage.truncated
                || assertions.contains(where: { $0.outcome != "pass" }) {
                errors
                    .append(
                        "Pass requires execution success, all checks passed, complete coverage and resolved cleanup"
                    )
            }
        }
        if assertions.contains(where: { $0.outcome == "fail" }), verdict != "fail" {
            errors.append("Failed assertions require verdict fail")
        }
        if verdict == "fail", !assertions.contains(where: { $0.outcome == "fail" }) {
            errors.append("Fail verdict requires a failed assertion")
        }
        if status == "done", execution != "succeeded" || verdict != "notAssessed" {
            errors.append("Done requires successful observation with verdict notAssessed")
        }
        if status == "fail", verdict != "fail" {
            errors.append("Fail status requires verdict fail")
        }
        if status == "blocked", !["notAssessed", "fail"].contains(verdict) {
            errors.append("Blocked status cannot carry a pass verdict")
        }
        return errors
    }
    // swiftlint:enable function_body_length cyclomatic_complexity
}

private extension AgentRunReport {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    func evidenceErrors(requested: Set<String>) -> [String] {
        var errors: [String] = []
        if Set(artifacts.map(\.path)).count != artifacts.count {
            errors.append("Duplicate artifact paths")
        }
        for artifact in artifacts {
            let scope = Set(artifact.checks)
            if artifact.runID != runID || scope.isEmpty || !scope.isSubset(of: requested)
                || scope.count != artifact.checks.count || artifact.path.count > 4096
                || !artifact.path.hasPrefix("/") || artifact.sha256.count != 64
                || sha256Hex(ofRegularFile: artifact.path, maximumBytes: 128 * 1024 * 1024) != artifact.sha256 {
                errors
                    .append("Artifact must match the run, requested checks and regular file SHA-256: \(artifact.path)")
            }
        }
        for assertion in assertions where assertion.evidence.contains(where: { path in
            !artifacts.contains { $0.path == path && $0.checks.contains(assertion.check) }
        }) {
            errors.append("Assertion \(assertion.check) references evidence outside its sealed scope")
        }
        return errors
    }
}
