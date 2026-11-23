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
            if let previous = kept.last, let wait = waitCall(trimmed),
               let priorWait = waitCall(previous.trimmingCharacters(in: .whitespaces)),
               priorWait.arguments == wait.arguments, previous == line || priorWait.seconds >= wait.seconds {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    private static func waitCall(_ line: String) -> (arguments: Substring, seconds: Double)? {
        guard let open = line.firstIndex(of: "("), line.last == ")",
              let timeout = line.range(of: ", timeout: ", options: .backwards), open < timeout.lowerBound else {
            return nil
        }
        let helper = line[..<open].split(separator: ".").last
        guard helper == "waitForHittability" || helper == "waitForExistence",
              line[..<open].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }) else {
            return nil
        }
        let value = line[timeout.upperBound...].dropLast()
        return (line[..<timeout.lowerBound], Double(value) ?? .nan)
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
    /// class gets the async pair by default. `tearDownLines` (from flow extensions) run after the
    /// failure attachments, which still need the app as the test left it.
    static func lifecycleSource(
        customBase: Bool,
        context: StudioTestContext?,
        setUpBody: String,
        tearDownLines: [String] = []
    ) -> String {
        let extensionTearDown = tearDownLines.map { "\n        \($0)" }.joined()
        return customBase
            ? """
            override func setUp() async throws {
                    try await super.setUp()
            \(setUpBody)
                }

                override func tearDown() async throws {
            \(failureAttachments)\(extensionTearDown)
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
            \(failureAttachments)\(extensionTearDown)
                    try super.tearDownWithError()
                }
            """
    }

    /// Refuses extension code the generated lifecycle cannot hold, rather than dropping it: `async`
    /// setup or teardown in XCTest's synchronous pair, or teardown where the harness owns teardown.
    static func checkExtensionLifecycle(
        _ code: StudioExtensionCode,
        asyncLifecycle: Bool,
        context: StudioTestContext?
    ) throws {
        if code.requiresAsync, !asyncLifecycle, !(code.setUp.isEmpty && code.tearDown.isEmpty) {
            throw TestCodeGeneratorError.unsupportedOnTarget(
                tool: StudioExtensionCode.operationTool,
                target: "XCUITest synchronous setUpWithError/tearDownWithError",
                reason: "a flow extension's setup or teardown needs async; set synchronousLifecycle to false"
                    + " with a custom base class, or have the extension emit blocking calls"
            )
        }
        if !code.tearDown.isEmpty, context?.synchronousLifecycle == true, context?.harnessOwnsApp == true {
            throw TestCodeGeneratorError.unsupportedOnTarget(
                tool: StudioExtensionCode.operationTool,
                target: "a harness that owns the app and its teardown",
                reason: "a flow extension's teardown has no tearDown override to run in; let the harness do it"
            )
        }
    }
}
