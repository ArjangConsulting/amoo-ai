import AmooCore

public extension TestSession {
    func recordSetup(milliseconds: Int) {
        verificationMetrics.setupMilliseconds = milliseconds
    }

    func configureVerification(checks: [String]) {
        verification = VerificationCoverage(checks: checks)
    }

    func recordVerification(
        id: String, outcome: VerificationCoverage.Outcome, reason: String, evidence: [String]
    ) {
        verification?.record(id: id, outcome: outcome, reason: redactor.redact(reason), evidence: evidence)
    }

    func recordClientResponse(bytes: Int, imageBytes: Int, dimensions: String?) {
        verificationMetrics.clientCalls += 1
        verificationMetrics.responseBytes += bytes
        verificationMetrics.imageBytes += imageBytes
        if let dimensions, verificationMetrics.imageDimensions.count < 128 {
            verificationMetrics.imageDimensions.append(dimensions)
        }
    }

    func recordOperation(milliseconds: Int, recovery: Bool, evidenceImageBytes: Int, dimensions: String?) {
        verificationMetrics.operations += 1
        verificationMetrics.evidenceImageBytes += evidenceImageBytes
        if let dimensions, verificationMetrics.imageDimensions.count < 128 {
            verificationMetrics.imageDimensions.append(dimensions)
        }
        if recovery {
            verificationMetrics.recoveryMilliseconds += milliseconds
        }
    }
}
