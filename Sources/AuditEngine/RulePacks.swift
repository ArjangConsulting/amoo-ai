import AmooCore

// MARK: - Security Rules

public struct DebugBuildExposureRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "SEC-001",
        title: "Debug Build Exposure",
        domain: .security,
        defaultSeverity: .medium,
        references: ["OWASP MASVS-RESILIENCE-1"]
    )

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let debugIndicators = ["debug", "staging", "dev mode", "test build"]
        let summary = input.screenContext.summary.lowercased()
        let matchedIndicators = debugIndicators.filter { summary.contains($0) }
        guard !matchedIndicators.isEmpty else { return [] }

        return [AuditFinding(
            id: "finding-\(metadata.id)-\(input.appID)",
            ruleID: metadata.id,
            severity: metadata.defaultSeverity,
            confidence: 0.7,
            summary: "Possible debug indicators visible: \(matchedIndicators.joined(separator: ", "))",
            remediation: "Disable debug indicators and test/staging labels in production builds.",
            evidence: [AuditEvidence(
                kind: .trace,
                summary: input.screenContext.summary,
                sourceRef: "screen-context",
                attributes: ["indicators": matchedIndicators.joined(separator: ",")]
            )],
            tags: ["security", "build"]
        )]
    }
}

public struct InsecureTextFieldRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "SEC-002",
        title: "Sensitive Field Without Secure Entry",
        domain: .security,
        defaultSeverity: .high,
        references: ["OWASP MASVS-STORAGE-1"]
    )

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let sensitiveLabels = ["password", "pin", "ssn", "credit card", "cvv", "secret", "token"]
        var findings: [AuditFinding] = []

        let textFields = input.elements.filter { $0.type == .textField && !$0.isSecureTextEntry }
        for field in textFields {
            let label = field.label.lowercased()
            let isSensitive = sensitiveLabels.contains { label.contains($0) }

            if isSensitive {
                findings.append(AuditFinding(
                    id: "finding-\(metadata.id)-\(field.id)",
                    ruleID: metadata.id,
                    severity: metadata.defaultSeverity,
                    confidence: 0.85,
                    summary: "Text field '\(field.label)' appears sensitive but is not using secure text entry.",
                    remediation: "Use SecureField (SwiftUI) or isSecureTextEntry (UIKit)"
                        + " for fields containing sensitive data.",
                    evidence: [AuditEvidence(
                        kind: .selector,
                        summary: "field=\(field.id) label=\(field.label) type=\(field.type?.rawValue ?? "unknown")",
                        sourceRef: field.id,
                        attributes: ["label": field.label, "type": field.type?.rawValue ?? ""]
                    )],
                    tags: ["security", "input", "privacy"]
                ))
            }
        }
        return findings
    }
}

public struct DeepLinkValidationRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "SEC-003",
        title: "Potential Unvalidated Deep Link Targets",
        domain: .security,
        defaultSeverity: .medium,
        references: ["OWASP MASVS-PLATFORM-2"]
    )

    public init() {}

    public func evidenceCoverage(_: AuditInput) -> AuditRuleEvaluation {
        AuditRuleEvaluation(
            ruleID: metadata.id,
            status: .insufficientEvidence,
            reason: "Screen inspection cannot establish URL validation; exercise explicit deep-link scenarios."
        )
    }

    public func evaluate(_: AuditInput) async throws -> [AuditFinding] {
        []
    }
}

// MARK: - Quality Rules

public struct ErrorStateHandlingRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "QA-001",
        title: "Missing Error State Feedback",
        domain: .quality,
        defaultSeverity: .medium,
        references: ["Internal quality guide"]
    )

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let errorKeywords = ["error", "failed", "something went wrong", "try again", "oops"]
        var findings: [AuditFinding] = []

        let errorElements = input.elements.filter { el in
            let label = el.label.lowercased()
            return errorKeywords.contains { label.contains($0) }
        }

        if !errorElements.isEmpty {
            let hasRetryButton = input.interactableElements.contains {
                let label = $0.label.lowercased()
                return label.contains("retry") || label.contains("try again") || label.contains("dismiss")
            }

            if !hasRetryButton {
                findings.append(AuditFinding(
                    id: "finding-\(metadata.id)-\(input.appID)",
                    ruleID: metadata.id,
                    severity: metadata.defaultSeverity,
                    confidence: 0.65,
                    summary: "Error state visible but no retry/dismiss action found.",
                    remediation: "Provide actionable buttons (Retry, Dismiss, Go Back) on error screens.",
                    evidence: errorElements.map {
                        AuditEvidence(kind: .selector, summary: $0.label, sourceRef: $0.id, attributes: [:])
                    },
                    tags: ["quality", "error-handling", "ux"]
                ))
            }
        }
        return findings
    }
}

public struct NavigationDeadEndRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "QA-002",
        title: "Navigation Dead End",
        domain: .quality,
        defaultSeverity: .low,
        references: ["Internal quality guide"]
    )

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        guard input.interactableElements.isEmpty else { return [] }

        let hasNavBar = containsType(input.hierarchy, type: .navigationBar)
        let hasTabBar = containsType(input.hierarchy, type: .tabBar)

        if !hasNavBar, !hasTabBar {
            return [AuditFinding(
                id: "finding-\(metadata.id)-\(input.appID)",
                ruleID: metadata.id,
                severity: metadata.defaultSeverity,
                confidence: 0.5,
                summary: "Screen has no interactable elements and no navigation controls.",
                remediation: "Ensure every screen has a way to navigate away"
                    + " (back button, tab bar, or dismiss gesture).",
                evidence: [AuditEvidence(
                    kind: .hierarchy,
                    summary: "root=\(input.hierarchy.id), interactable=0",
                    sourceRef: "hierarchy",
                    attributes: [:]
                )],
                tags: ["quality", "navigation"]
            )]
        }
        return []
    }

    private func containsType(_ node: ViewNode, type: ElementType, depth: Int = 0) -> Bool {
        // Hard depth cap: a hostile or malformed companion could hand us a cyclic
        // hierarchy and a naive recursion would blow the stack.
        if depth >= maxHierarchyDepth {
            return false
        }
        if node.type == type {
            return true
        }
        return node.children.contains { containsType($0, type: type, depth: depth + 1) }
    }
}

// MARK: - UX Rules

public struct MissingAccessibilityLabelRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "UX-001",
        title: "Interactable Elements Missing Accessibility Labels",
        domain: .ux,
        defaultSeverity: .medium,
        references: ["WCAG 2.1 - 1.1.1", "Apple HIG - Accessibility"]
    )

    public init() {}

    /// Depends on `getInteractableElements` reporting elements that carry neither an identifier
    /// nor a label. A companion that filters those out before answering leaves this rule unable
    /// to fire at all — it will find nothing and report a clean screen, which is the one outcome
    /// it must never produce by accident.
    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let unlabeled = input.interactableElements.filter { el in
            el.label.trimmingCharacters(in: .whitespaces).isEmpty && el.id.isEmpty
        }

        guard !unlabeled.isEmpty else { return [] }

        return [AuditFinding(
            id: "finding-\(metadata.id)-\(input.appID)",
            ruleID: metadata.id,
            severity: metadata.defaultSeverity,
            confidence: 0.9,
            summary: "\(unlabeled.count) interactable element(s) have no accessibility label or identifier.",
            remediation: "Add accessibilityLabel or accessibilityIdentifier to all interactive controls.",
            evidence: unlabeled.prefix(5).map { el in
                AuditEvidence(
                    kind: .selector,
                    summary: "type=\(el.type?.rawValue ?? "unknown")",
                    sourceRef: el.id.isEmpty ? "anonymous-\(el.type?.rawValue ?? "element")" : el.id,
                    attributes: ["type": el.type?.rawValue ?? ""]
                )
            },
            tags: ["ux", "accessibility", "a11y"]
        )]
    }
}

public struct SmallTapTargetRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "UX-002",
        title: "Small Tap Target",
        domain: .ux,
        defaultSeverity: .medium,
        references: ["WCAG 2.1 - 2.5.5", "Apple HIG - 44pt minimum"]
    )

    private let minimumSize: Double = 44.0

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let tooSmall = input.interactableElements.filter { el in
            guard let frame = el.frame else { return false }
            return frame.width < minimumSize || frame.height < minimumSize
        }

        guard !tooSmall.isEmpty else { return [] }

        return [AuditFinding(
            id: "finding-\(metadata.id)-\(input.appID)",
            ruleID: metadata.id,
            severity: metadata.defaultSeverity,
            confidence: 0.85,
            summary: "\(tooSmall.count) interactive element(s) have tap targets smaller than \(Int(minimumSize))pt.",
            remediation: "Ensure all interactive elements have a minimum tap target of 44x44pt per Apple HIG.",
            evidence: tooSmall.prefix(5).compactMap { el -> AuditEvidence? in
                guard let frame = el.frame else { return nil }
                return AuditEvidence(
                    kind: .selector,
                    summary: "\(el.label.isEmpty ? el.id : el.label): \(Int(frame.width))x\(Int(frame.height))pt",
                    sourceRef: el.id,
                    attributes: ["width": "\(frame.width)", "height": "\(frame.height)"]
                )
            },
            tags: ["ux", "accessibility", "tap-target"]
        )]
    }
}

// MARK: - Testability Rules

public struct MissingStableIdentifierRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "TEST-001",
        title: "Missing Stable Identifiers",
        domain: .testability,
        defaultSeverity: .low,
        references: ["Internal testability guide"]
    )

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let interactableWithoutID = input.interactableElements.filter {
            $0.id.trimmingCharacters(in: .whitespaces).isEmpty
        }

        guard !interactableWithoutID.isEmpty else { return [] }

        let total = input.interactableElements.count
        let missing = interactableWithoutID.count
        let percentage = total > 0 ? Int(Double(missing) / Double(total) * 100) : 0

        return [AuditFinding(
            id: "finding-\(metadata.id)-\(input.appID)",
            ruleID: metadata.id,
            severity: percentage > 50 ? .medium : metadata.defaultSeverity,
            confidence: 0.8,
            summary: "\(missing)/\(total) (\(percentage)%)"
                + " interactable elements lack stable accessibility identifiers.",
            remediation: "Assign accessibilityIdentifier to all interactive controls"
                + " for reliable test automation.",
            evidence: interactableWithoutID.prefix(5).map { el in
                AuditEvidence(
                    kind: .selector,
                    summary: "label=\(el.label) type=\(el.type?.rawValue ?? "unknown")",
                    sourceRef: el.label.isEmpty ? "anonymous" : el.label,
                    attributes: ["type": el.type?.rawValue ?? ""]
                )
            },
            tags: ["testability", "selectors", "automation"]
        )]
    }
}

public struct HierarchyDepthRule: AuditRule {
    public let metadata = AuditRuleMetadata(
        id: "TEST-002",
        title: "Excessive View Hierarchy Depth",
        domain: .testability,
        defaultSeverity: .low,
        references: ["Internal testability guide"]
    )

    private let maxRecommendedDepth = 15

    public init() {}

    public func evaluate(_ input: AuditInput) async throws -> [AuditFinding] {
        let depth = measureDepth(input.hierarchy)
        guard depth > maxRecommendedDepth else { return [] }

        return [AuditFinding(
            id: "finding-\(metadata.id)-\(input.appID)",
            ruleID: metadata.id,
            severity: metadata.defaultSeverity,
            confidence: 0.75,
            summary: "View hierarchy depth is \(depth) levels (recommended max: \(maxRecommendedDepth)).",
            remediation: "Deep hierarchies slow element queries and increase flakiness."
                + " Consider flattening the view structure.",
            evidence: [AuditEvidence(
                kind: .hierarchy,
                summary: "depth=\(depth), root=\(input.hierarchy.id)",
                sourceRef: "hierarchy",
                attributes: ["depth": "\(depth)"]
            )],
            tags: ["testability", "performance", "hierarchy"]
        )]
    }

    private func measureDepth(_ node: ViewNode, depth: Int = 0) -> Int {
        // Cap recursion: a malformed hierarchy from the companion could be cyclic.
        if depth >= maxHierarchyDepth {
            return depth
        }
        if node.children.isEmpty {
            return 1
        }
        return 1 + (node.children.map { measureDepth($0, depth: depth + 1) }.max() ?? 0)
    }
}

/// Hard cap on view hierarchy traversal depth. Prevents stack overflow when
/// a companion sends a cyclic or pathologically deep tree.
private let maxHierarchyDepth = 256

// MARK: - Rule Pack Collections

public enum RulePacks {
    public static var security: [any AuditRule] {
        [DebugBuildExposureRule(), InsecureTextFieldRule(), DeepLinkValidationRule()]
    }

    public static var quality: [any AuditRule] {
        [ErrorStateHandlingRule(), NavigationDeadEndRule()]
    }

    public static var ux: [any AuditRule] {
        [MissingAccessibilityLabelRule(), SmallTapTargetRule()]
    }

    public static var testability: [any AuditRule] {
        [MissingStableIdentifierRule(), HierarchyDepthRule()]
    }

    public static var all: [any AuditRule] {
        security + quality + ux + testability
    }
}
