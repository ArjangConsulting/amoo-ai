public enum AuditTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "audit_app",
            description: "Inspect the current app screen for audit findings."
                + " Evaluates security, quality, UX, and testability rules against the current UI state.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name"),
                "rule_packs": .init(
                    type: "string",
                    description: "Comma-separated list of rule packs to run:"
                        + " security, quality, ux, testability, all. Defaults to all."
                ),
                "fail_on": .init(
                    type: "string",
                    description: "Minimum severity to fail on: critical, high, medium, low."
                        + " Omit for a report without a failure threshold."
                )
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "audit_accessibility",
            description: "Check the current screen for accessibility issues:"
                + " missing labels, small tap targets, and missing identifiers.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name")
            ],
            required: ["app_id"]
        ),
        ToolDefinition(
            name: "audit_security",
            description: "Check the current screen for security issues:"
                + " debug indicators and insecure text fields. Deep-link validation requires scenario evidence.",
            properties: [
                "app_id": .init(type: "string", description: "The app's bundle identifier or package name")
            ],
            required: ["app_id"]
        )
    ]
}
