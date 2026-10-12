import StudioProtocol

extension XCUITestEmitter {
    /// The import and the `setUpWithError` lines for a context's `requiredIdiom`, or empty strings.
    ///
    /// The guard needs UIKit, and sits before the launch so a skipped test costs nothing.
    static func idiomGuard(for context: StudioTestContext?) -> (importLine: String, guardLines: String) {
        guard let idiom = context?.requiredIdiom else { return ("", "") }
        let device = idiom == .phone ? "iPhone" : "iPad"
        let guardLines = """

                try XCTSkipUnless(
                    UIDevice.current.userInterfaceIdiom == .\(idiom.rawValue),
                    "Recorded for \(device); skipped on the other device class"
                )
        """
        return ("\nimport UIKit", guardLines)
    }
}
