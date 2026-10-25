import StudioProtocol

extension EspressoEmitter {
    static let stateDescriptionMatcher = """
        private fun hasNativeStateDescription(expected: String, contains: Boolean): Matcher<View> {
            check(android.os.Build.VERSION.SDK_INT >= 30) { "Native stateDescription requires API 30+" }
            return object : TypeSafeMatcher<View>() {
                override fun describeTo(description: Description) {
                    description.appendText("native stateDescription ").appendValue(expected)
                }
                override fun matchesSafely(view: View): Boolean {
                    val actual = view.stateDescription?.toString() ?: ""
                    return if (contains) actual.contains(expected) else actual == expected
                }
            }
        }
    """
}
