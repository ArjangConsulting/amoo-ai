import StudioProtocol

extension XCUITestEmitter {
    /// The failure screenshot and hierarchy `tearDownWithError` attaches, at method-body indentation.
    static let failureAttachments = """
            if testRun?.failureCount ?? 0 > 0 {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Failure screenshot"
                screenshot.lifetime = .keepAlways
                add(screenshot)

                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "Failure UI hierarchy"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
    """

    /// Waits for an existing element's selected state to equal `expected`. Emitted only when the
    /// test asserts selection; existence is waited for separately, so a missing element and an
    /// unselected one fail with different messages.
    static let selectionHelper = """
        private func waitForSelection(
            _ element: XCUIElement,
            expected: Bool,
            named name: String = "Element",
            timeout: TimeInterval? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertTrue(
                element.wait(for: \\.isSelected, toEqual: expected, timeout: timeout ?? defaultTimeout),
                "\\(name) was expected to be \\(expected ? "selected" : "unselected"), but isSelected was"
                    + " \\(element.isSelected) after the timeout.\\n\\(element.debugDescription)",
                file: file,
                line: line
            )
        }


    """

    /// Drops the blank line a re-used element's empty declaration leaves behind, and a wait that
    /// repeats the line before it. `assert_visible(x)` followed by `tap_element(x)` waited for the same
    /// element twice in a row — the second wait proves nothing the first did not.
    static func collapsingRepeatedWaits(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            // A context may bind the waits to its own helpers (`TestCommonsXCUI.waitForHittability(`),
            // so any adjacent repeat of a wait call collapses, not only the generated helpers' names.
            let isWait = trimmed.contains("waitForHittability(") || trimmed.contains("waitForExistence(")
            if isWait, kept.last == line {
                continue
            }
            // A tap expectation's wait followed by the next tap's own wait on the same element differ
            // only in timeout; the first one already proved it, with the longer, explicit timeout.
            if isWait, let previous = kept.last, let target = waitTarget(trimmed),
               waitTarget(previous.trimmingCharacters(in: .whitespaces)) == target {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The wait helper a line calls and the element it waits on: `waitForHittability(row, …)` →
    /// `("waitForHittability", "row")`.
    static func waitTarget(_ line: String) -> String? {
        for helper in ["waitForHittability(", "waitForExistence("] {
            guard let call = line.range(of: helper) else { continue }
            let rest = line[call.upperBound...]
            let element = rest.prefix { $0 != "," && $0 != ")" }.trimmingCharacters(in: .whitespaces)
            return element.isEmpty ? nil : helper + element
        }
        return nil
    }

    static func launchConfiguration(for test: StudioAuthoredTest) -> String {
        guard let requirements = test.requirements else { return "" }
        var lines: [String] = []
        if requirements.launchArguments.isEmpty == false {
            let joined = requirements.launchArguments.map(literal).joined(separator: ", ")
            lines.append("        app.launchArguments = [\(joined)]")
        }
        for (key, value) in requirements.launchEnvironment.sorted(by: { $0.key < $1.key }) {
            lines.append("        app.launchEnvironment[\(literal(key))] = \(literal(value))")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The setUp / tearDown overrides for the generated class; see `generate` for why a custom base
    /// class gets the async pair by default.
    static func lifecycleSource(customBase: Bool, context: StudioTestContext?, setUpBody: String) -> String {
        customBase
            ? """
            override func setUp() async throws {
                    try await super.setUp()
            \(setUpBody)
                }

                override func tearDown() async throws {
            \(failureAttachments)
                    try await super.tearDown()
                }
            """
            : context?.synchronousLifecycle == true && context?.harnessOwnsApp == true
            // A harness that owns the app attaches its own failure diagnostics, and its lifecycle may be
            // nonisolated, where an override cannot touch the main-actor `app`: no teardown override.
            ? """
            override func setUpWithError() throws {
                    try super.setUpWithError()
            \(setUpBody)
                }
            """
            : """
            override func setUpWithError() throws {
                    try super.setUpWithError()
            \(setUpBody)
                }

                override func tearDownWithError() throws {
            \(failureAttachments)
                    try super.tearDownWithError()
                }
            """
    }
}
