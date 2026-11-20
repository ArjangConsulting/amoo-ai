extension ComposeEspressoEmitter {
    /// The test method's body: the harness's `wrapper { … }` when the context names one, else a
    /// launch intent carrying the recording's launch environment as string extras, the way
    /// `device_launch_app` delivered it, so the test runs against the same configuration.
    static func launchBlock(body: String, wrapper: String?, environment: [String: String]) -> String {
        if let wrapper {
            return "        \(wrapper) {\n\(body)\n        }"
        }
        let extras = environment.sorted { $0.key < $1.key }
            .map { "        launchIntent.putExtra(\(literal($0.key)), \(literal($0.value)))\n" }
            .joined()
        return """
                val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
                val launchIntent = requireNotNull(
                    targetContext.packageManager.getLaunchIntentForPackage(targetContext.packageName)
                ) { "No launcher activity found for ${targetContext.packageName}" }
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
        \(extras)
                ActivityScenario.launch<Activity>(launchIntent).use {
        \(body)
                }
        """
    }
}
