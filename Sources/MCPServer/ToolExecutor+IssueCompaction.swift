extension DriverToolExecutor {
    static func compactingIssueResponse(
        _ original: ToolResult,
        tool: String,
        arguments: [String: String]
    ) -> ToolResult {
        guard ["audit_accessibility_native", "test_voiceover", "test_talkback", "assert_talkback_speech"]
            .contains(tool),
            arguments["response_mode"] != "full", let report = original.structuredContent else { return original }
        var response = original
        response.structuredContent = compactingIssues(report)
        return response
    }

    /// `report` with each issue's repeated provenance written once.
    ///
    /// Every native audit issue carried the same six `semantics.attributes` strings, a `fullFrame`
    /// equal to its `frame` and empty hierarchy fields: about 600 of its 900 bytes, so twelve issues
    /// cost 13KB. Attributes shared by every issue move to `issueAttributes` on the report; an issue
    /// keeps only the attributes that differ. A `fullFrame` equal to `frame` and empty strings are
    /// dropped. Nothing else changes.
    static func compactingIssues(_ report: Value) -> Value {
        guard case var .object(fields) = report, case let .array(issues)? = fields["issues"], issues.count > 1 else {
            return report
        }
        let attributeSets = issues.map { issue -> [String: Value] in
            issue.objectValue?["semantics"]?.objectValue?["attributes"]?.objectValue ?? [:]
        }
        let shared = attributeSets.dropFirst().reduce(attributeSets.first ?? [:]) { common, attributes in
            common.filter { attributes[$0.key] == $0.value }
        }
        fields["issues"] = .array(issues.map { compactIssue($0, shared: shared) })
        if !shared.isEmpty {
            fields["issueAttributes"] = .object(shared)
        }
        return .object(fields)
    }

    private static func compactIssue(_ issue: Value, shared: [String: Value]) -> Value {
        guard case var .object(fields) = issue else { return issue }
        if case var .object(semantics)? = fields["semantics"] {
            if case let .object(attributes)? = semantics["attributes"] {
                let own = attributes.filter { shared[$0.key] != $0.value }
                semantics["attributes"] = own.isEmpty ? nil : .object(own)
            }
            if semantics["fullFrame"] == fields["frame"] {
                semantics["fullFrame"] = nil
            }
            semantics = semantics.filter { $0.value != .string("") }
            fields["semantics"] = semantics.isEmpty ? nil : .object(semantics)
        }
        return .object(fields.filter { $0.value != .string("") })
    }
}
