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
            let isWait = trimmed.hasPrefix("waitForHittability(") || trimmed.hasPrefix("waitForExistence(")
            if isWait, kept.last == line {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
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
}
