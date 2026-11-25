import StudioProtocol

extension XCUITestEmitter {
    /// `source` with its waits answering an Apple password prompt, for a test whose flow asked amoo to
    /// answer system prompts (`dismiss_system_dialogs`). Other tests are returned unchanged.
    ///
    /// amoo answers such a prompt when a step fails behind it and runs the step once more; the
    /// generated waits do the same: when one times out and a prompt covers the app, they press its Not
    /// Now (never Save) and wait once more. iOS draws "Save Password?" in Safari's view service, over
    /// the app, so the helper looks there as well as in the app.
    static func answeringSystemPrompts(_ source: String, test: StudioAuthoredTest) -> String {
        guard test.platform == .ios, test.compiledPlan?.dismissSystemDialogs == true,
              let helpers = source.range(of: "    private func replaceText(") else { return source }
        var source = source
        source.insert(contentsOf: systemPromptHelpers, at: helpers.lowerBound)
        for condition in waitConditions {
            // The plain helpers assert the condition, so it is wrapped and a timeout only waits again
            // after a prompt was answered.
            source = source.replacingOccurrences(
                of: "            \(condition),\n",
                with: "            waitAnsweringSystemPrompt { \(condition) },\n"
            )
        }
        for (call, condition) in zip(testCommonsCalls, waitConditions) {
            // TestCommons asserts inside, so its wait is preceded by one that answers a prompt.
            source = source.replacingOccurrences(
                of: "        \(call)(\n",
                with: "        _ = waitAnsweringSystemPrompt { \(condition) }\n        \(call)(\n"
            )
        }
        return source
    }

    private static let waitConditions = [
        "element.waitForExistence(timeout: timeout ?? defaultTimeout)",
        "element.wait(for: \\.isHittable, toEqual: true, timeout: timeout ?? defaultTimeout)",
        "element.wait(for: \\.exists, toEqual: false, timeout: timeout ?? defaultTimeout)"
    ]

    private static let testCommonsCalls = [
        "TestCommonsXCUI.waitForExistence",
        "TestCommonsXCUI.waitForHittability",
        "TestCommonsXCUI.waitForAbsence"
    ]

    static let systemPromptHelpers = """
        /// Whether `condition` holds, waiting once more after answering an Apple password prompt
        /// that covers the app, as amoo's `dismiss_system_dialogs` does.
        private func waitAnsweringSystemPrompt(_ condition: () -> Bool) -> Bool {
            if condition() {
                return true
            }
            return answerSystemPasswordPrompt() && condition()
        }

        /// Presses the harmless button of an Apple password prompt ("Save Password?") in the app or
        /// in Safari's view service, which draws it. Never presses Save. Returns whether it answered one.
        private func answerSystemPasswordPrompt() -> Bool {
            let titles = [
                "Save Password", "Save this password", "Would you like to save this password", "Update Password",
                "Update saved password", "Sign in to Apple Account"
            ]
            let titled = NSCompoundPredicate(
                orPredicateWithSubpredicates: titles.map { NSPredicate(format: "label BEGINSWITH[c] %@", $0) }
            )
            let kinds = NSPredicate(
                format: "elementType IN %@",
                [XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.alert.rawValue]
            )
            let promptQuery = NSCompoundPredicate(andPredicateWithSubpredicates: [kinds, titled])
            for host in [app, XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")] {
                guard host.state != .notRunning, host.state != .unknown else { continue }
                let prompt = host.descendants(matching: .any).matching(promptQuery).firstMatch
                guard prompt.exists else { continue }
                for label in ["Not Now", "Cancel", "No Thanks", "Don't Save"] {
                    let button = prompt.buttons[label].firstMatch
                    if button.exists {
                        button.tap()
                        return prompt.wait(for: \\.exists, toEqual: false, timeout: 5)
                    }
                }
            }
            return false
        }


    """
}
