// swiftlint:disable multiline_arguments
import AmooCore
import MCP

extension DriverToolExecutor {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func executeStateAssertion(
        tool: String, arguments: [String: String], driver: any PlatformDriver
    ) async throws -> ToolResult {
        guard let selector = try preferredSelector(arguments: arguments, includeDescription: true) else {
            throw ToolExecutionError(code: "invalid_argument", message: "An element selector is required")
        }
        let checked = tool == "assert_checked"
        let expected: Value
        if checked {
            expected = try .bool(Self.parseExpectedSelection(arguments["expected"]))
        } else {
            guard (arguments["expected"] != nil) != (arguments["contains"] != nil) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "Provide exactly one of expected or contains"
                )
            }
            expected = .string(arguments["expected"] ?? arguments["contains"] ?? "")
        }
        let started = ContinuousClock.now
        let deadline = started + .milliseconds(max(1, arguments["timeout_ms"].flatMap(Int.init) ?? 5000))
        let pick = try ElementPick.parse(arguments)
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        var fields: [String: Value] = [
            "passed": .bool(false), "property": .string(checked ? "checked" : "state_description"),
            "expected": expected, "observed": .null,
            "selector": .string(Self.describeConstraints(selector)), "dispatch_status": .string("not_applicable")
        ]
        repeat {
            try Task.checkCancellation()
            do {
                let match = try await OperationDeadline.read(until: deadline) {
                    try await self.resolveElement(
                        selector: selector, driver: driver, appID: appID, pick: pick, missingIsNil: true
                    )
                }
                fields["last_observation_status"] = .string(match == nil ? "no_match" : "query_completed")
                if let match {
                    fields["element_id"] = .string(match.id)
                    let actual: Value? = if checked {
                        match.semantics?.isCheckable == true
                            ? match.semantics?.isChecked.map(Value.bool) : nil
                    } else {
                        match.semantics?.stateDescription.map(Value.string)
                    }
                    guard let actual else {
                        fields["failure_kind"] = .string("unsupported_property")
                        fields["code"] = .string("state_property_unsupported")
                        return ToolResult(
                            content: "\(tool) unsupported: provider did not report the applicable native property.",
                            isError: true, structuredContent: .object(fields)
                        )
                    }
                    fields["observed"] = actual
                    let matches = if let substring = arguments["contains"], !checked {
                        actual.stringValue?.contains(substring) == true
                    } else {
                        actual == expected
                    }
                    if matches {
                        fields["passed"] = .bool(true)
                        return .success("Native state assertion matched.", structuredContent: .object(fields))
                    }
                }
            } catch let error as ToolExecutionError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fields["failure_kind"] = .string("observation_failed")
                fields["observation_error"] = .string(String(describing: error))
                fields["companion_health"] = .string("unconfirmed")
                break
            }
            try? await Task.sleep(until: min(deadline, .now + .milliseconds(100)), clock: .continuous)
        } while ContinuousClock.now < deadline
        let elapsed = started.duration(to: .now).components
        fields["elapsed_ms"] = .int(Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
        fields["failure_kind"] = fields["failure_kind"] ?? .string("assertion_mismatch")
        fields["device_health"] = .string("unconfirmed")
        return ToolResult(
            content: "Native state assertion did not complete successfully; see expected and last observed state.",
            isError: true, structuredContent: .object(fields)
        )
    }
}

// swiftlint:enable multiline_arguments
