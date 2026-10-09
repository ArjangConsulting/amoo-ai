public enum AuditTools {
    public static let names = definitions.map(\.name)

    /// A threshold yields verdict=fail on a qualifying finding, and verdict=pass only when every selected
    /// rule was evaluated. Scenario-only rules such as SEC-003 (deep links) keep a clean screen notAssessed.
    private static let failOnProperty = ToolInputProperty(
        type: "string",
        description: "Minimum severity to fail on: critical, high, medium, low, info."
            + " Omit for a report without a verdict. verdict=pass also requires every selected rule to be"
            + " evaluated; rules that need scenario evidence (SEC-003 deep links) leave the verdict notAssessed."
    )

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "assert_accessibility_journey",
            description: "Run an authored accessibility journey on iOS 27 in one continuous VoiceOver lifetime."
                + " Checks exported name/role/state, bounded speech order and focus recovery after targeted gestures."
                + " Returns checkpoint evidence and coverage; restores VoiceOver. Not whole-app conformance."
                + " Generated-test export is unsupported and explicitly blocks complete export.",
            properties: [
                "app_id": .init(type: "string", description: "Foreground app bundle ID"),
                "journey": .init(
                    type: "string",
                    description: "JSON AccessibilityJourney: schemaVersion=1,id,steps."
                        + " Each named step has kind element,seek,order,transition. See docs/accessibility-journeys.md."
                        + " 1...20 steps, at most 30 moves; expectations must be explicit."
                ),
                "record_speech": .init(type: "boolean", description: "Persist raw speech evidence; default false")
            ],
            required: ["app_id", "journey"],
            outputSchema: .init(
                properties: [
                    "executionStatus": .init(type: "string", description: "succeeded, failed, unsupported or unknown"),
                    "verdict": .init(
                        type: "string",
                        description: "pass, fail or notAssessed for authored expectations"
                    ),
                    "cleanupStatus": .init(type: "string", description: "restored, failed or unknown"),
                    "requestedChecks": .init(type: "array", description: "Authored check IDs"),
                    "evaluatedChecks": .init(type: "array", description: "Checks evaluated as pass or fail"),
                    "notEvaluatedReasons": .init(type: "object", description: "Coverage gaps by check ID"),
                    "journey": .init(type: "object", description: "Versioned checks and checkpoint evidence"),
                    "truncated": .init(type: "boolean", description: "Evidence bounds exceeded")
                ],
                required: ["executionStatus", "verdict", "cleanupStatus", "requestedChecks", "evaluatedChecks"]
            )
        ),
        ToolDefinition(
            name: "audit_accessibility_native",
            description: "Run Apple's native current-screen accessibility audit on iOS."
                + " Returns findings and coverage, not whole-app conformance.",
            properties: [
                "app_id": .init(type: "string", description: "Foreground app bundle ID"),
                "categories": .init(
                    type: "string",
                    description: "Comma-separated contrast,elementDetection,hitRegion,sufficientElementDescription,"
                        + "dynamicType,textClipped,trait. Defaults to all supported iOS categories."
                )
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "test_voiceover",
            description: "Observe bounded public VoiceOver traversal on iOS 27+. Restores original enabled state."
                + " Does not activate controls or test rotor/custom actions.",
            properties: [
                "app_id": .init(type: "string", description: "Foreground app bundle ID"),
                "steps": .init(type: "integer", description: "1...30 focus moves; default 5"),
                "direction": .init(type: "string", description: "forward (default) or backward"),
                "phases": .init(
                    type: "string",
                    description: "JSON array of {steps,direction}; 1...6 phases,"
                        + " at most 30 moves total. Omit steps/direction. Focus persists between phases."
                ),
                "record_speech": .init(
                    type: "boolean",
                    description: "Persist speech in the session report; default false."
                        + " Known session secrets are redacted even when enabled."
                )
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "audit_app",
            description: "Inspect the current app screen for audit findings."
                + " Evaluates security, quality, UX, and testability rules against the current UI state.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
                "rule_packs": .init(
                    type: "string",
                    description: "Comma-separated list of rule packs to run:"
                        + " security, quality, ux, accessibility, testability, all. Defaults to all."
                ),
                "fail_on": failOnProperty
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "audit_accessibility",
            description: "Inspect current-screen naming and bounds concerns using scoped heuristics."
                + " Missing automation identifiers are testability concerns, not accessibility defects."
                + " Other accessibility properties require native semantics or authored task evidence.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
                "fail_on": failOnProperty
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "audit_security",
            description: "Check the current screen for security issues:"
                + " debug indicators and insecure text fields. Deep-link validation requires scenario evidence.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
                "fail_on": failOnProperty
            ],
            required: ["app_id"]
        )
    ]
}
