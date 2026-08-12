import AmooCore

public enum AuditDomain: String, Sendable {
    case security
    case quality
    case ux
    case testability
}

public enum Severity: String, Sendable {
    case critical
    case high
    case medium
    case low
    case info
}

public struct AuditRuleMetadata: Sendable {
    public var id: String
    public var title: String
    public var domain: AuditDomain
    public var defaultSeverity: Severity
    public var references: [String]

    public init(id: String, title: String, domain: AuditDomain, defaultSeverity: Severity, references: [String]) {
        self.id = id
        self.title = title
        self.domain = domain
        self.defaultSeverity = defaultSeverity
        self.references = references
    }
}

public enum EvidenceKind: String, Sendable {
    case hierarchy
    case selector
    case screenshot
    case log
    case config
    case trace
}

public struct AuditEvidence: Sendable {
    public var kind: EvidenceKind
    public var summary: String
    public var sourceRef: String
    public var attributes: [String: String]

    public init(kind: EvidenceKind, summary: String, sourceRef: String, attributes: [String: String]) {
        self.kind = kind
        self.summary = summary
        self.sourceRef = sourceRef
        self.attributes = attributes
    }
}

public struct AuditFinding: Sendable {
    public var id: String
    public var ruleID: String
    public var severity: Severity
    public var confidence: Double
    public var summary: String
    public var remediation: String
    public var evidence: [AuditEvidence]
    public var tags: [String]

    public init(
        id: String,
        ruleID: String,
        severity: Severity,
        confidence: Double,
        summary: String,
        remediation: String,
        evidence: [AuditEvidence],
        tags: [String]
    ) {
        self.id = id
        self.ruleID = ruleID
        self.severity = severity
        self.confidence = confidence
        self.summary = summary
        self.remediation = remediation
        self.evidence = evidence
        self.tags = tags
    }
}

public struct AuditInput: Sendable {
    public var appID: String
    public var screenContext: ScreenContext
    public var hierarchy: ViewNode
    public var elements: [ElementInfo]
    public var interactableElements: [ElementInfo]

    public init(
        appID: String,
        screenContext: ScreenContext,
        hierarchy: ViewNode,
        elements: [ElementInfo] = [],
        interactableElements: [ElementInfo] = []
    ) {
        self.appID = appID
        self.screenContext = screenContext
        self.hierarchy = hierarchy
        self.elements = elements
        self.interactableElements = interactableElements
    }
}

public protocol AuditRule: Sendable {
    var metadata: AuditRuleMetadata { get }
    func evaluate(_ input: AuditInput) async throws -> [AuditFinding]
}

public struct AuditReport: Sendable {
    public var appID: String
    public var findings: [AuditFinding]

    public init(appID: String, findings: [AuditFinding]) {
        self.appID = appID
        self.findings = findings
    }
}
