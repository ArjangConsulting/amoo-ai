/// The import and launch fragments of a generated Espresso test, in standalone and shared modes.
extension EspressoEmitter {
    /// The body-driven, truly optional import fragments, accumulated in `generate`.
    struct ImportFragments {
        var scroll: String
        var ancestor: String
        var nativeState: String
        var allOf: String
        var gesture: String
        var context: String
    }

    static func standaloneImports(_ fragments: ImportFragments) -> String {
        """
        import android.app.Activity
        import android.content.Intent
        import android.os.SystemClock
        import android.view.View\(fragments.gesture)
        import androidx.test.core.app.ActivityScenario
        import androidx.test.espresso.Espresso.onView
        import androidx.test.espresso.Espresso.pressBack
        import androidx.test.espresso.PerformException
        import androidx.test.espresso.UiController
        import androidx.test.espresso.ViewAction
        import androidx.test.espresso.action.ViewActions.click
        import androidx.test.espresso.action.ViewActions.replaceText\(fragments.scroll)
        import androidx.test.espresso.action.ViewActions.swipeDown
        import androidx.test.espresso.action.ViewActions.swipeLeft
        import androidx.test.espresso.action.ViewActions.swipeRight
        import androidx.test.espresso.action.ViewActions.swipeUp
        import androidx.test.espresso.assertion.ViewAssertions.matches
        import androidx.test.espresso.matcher.ViewMatchers.hasFocus
        import androidx.test.espresso.matcher.ViewMatchers.isDisplayed
        import androidx.test.espresso.matcher.ViewMatchers.isEnabled
        import androidx.test.espresso.matcher.ViewMatchers.isRoot\(fragments.ancestor)\(fragments.nativeState)
        import androidx.test.espresso.matcher.ViewMatchers.withContentDescription
        import androidx.test.espresso.matcher.ViewMatchers.withText
        import androidx.test.ext.junit.runners.AndroidJUnit4
        import androidx.test.platform.app.InstrumentationRegistry
        import androidx.test.espresso.util.HumanReadables
        import androidx.test.espresso.util.TreeIterables
        import org.hamcrest.Description
        import org.hamcrest.Matcher
        import org.hamcrest.Matchers.containsString
        import org.hamcrest.Matchers.anyOf\(fragments.allOf)
        import org.hamcrest.TypeSafeMatcher
        import org.junit.Test
        import org.junit.runner.RunWith
        import java.util.concurrent.TimeoutException\(fragments.context.isEmpty ? "" : "\n\(fragments.context)")
        """
    }

    static func sharedImports(
        body: String,
        nativeStateImports: String,
        gestureImports: String,
        contextImports: String
    ) -> String {
        let sharedFunctions = ["waitUntilDisplayed", "waitUntilNotDisplayed", "hasResourceEntryName", "withIndex"]
            .filter { body.contains("\($0)(") }
            .map { "import io.github.maniramezan.testcommons.device.\($0)" }
        let optional = [
            ("scrollTo()", "import androidx.test.espresso.action.ViewActions.scrollTo"),
            ("isDescendantOfA(", "import androidx.test.espresso.matcher.ViewMatchers.isDescendantOfA"),
            ("allOf(", "import org.hamcrest.Matchers.allOf")
        ]
        .filter { body.contains($0.0) }
        .map(\.1)
        let fixed = [
            "import androidx.test.espresso.Espresso.onView",
            "import androidx.test.espresso.Espresso.pressBack",
            "import androidx.test.espresso.action.ViewActions.click",
            "import androidx.test.espresso.action.ViewActions.replaceText",
            "import androidx.test.espresso.action.ViewActions.swipeDown",
            "import androidx.test.espresso.action.ViewActions.swipeLeft",
            "import androidx.test.espresso.action.ViewActions.swipeRight",
            "import androidx.test.espresso.action.ViewActions.swipeUp",
            "import androidx.test.espresso.assertion.ViewAssertions.matches",
            "import androidx.test.espresso.matcher.ViewMatchers.hasFocus",
            "import androidx.test.espresso.matcher.ViewMatchers.isDisplayed",
            "import androidx.test.espresso.matcher.ViewMatchers.isEnabled",
            "import androidx.test.espresso.matcher.ViewMatchers.isRoot",
            "import androidx.test.espresso.matcher.ViewMatchers.withContentDescription",
            "import androidx.test.espresso.matcher.ViewMatchers.withText",
            "import androidx.test.ext.junit.runners.AndroidJUnit4",
            "import io.github.maniramezan.testcommons.device.launchTargetApp",
            "import org.hamcrest.Matchers.anyOf",
            "import org.hamcrest.Matchers.containsString",
            "import org.junit.Test",
            "import org.junit.runner.RunWith"
        ]
        // The library covers the wait and identity helpers only; shared drag-and-drop and native
        // state assertions still paste their helpers and need their imports like standalone does.
        let helperImports = (nativeStateImports + gestureImports)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        // The pasted gesture helpers reference Espresso types the shared body does not.
        let gestureHelperImports = gestureImports.isEmpty ? [] : [
            "import android.os.SystemClock",
            "import android.view.View",
            "import androidx.test.espresso.PerformException",
            "import androidx.test.espresso.UiController",
            "import androidx.test.espresso.ViewAction",
            "import androidx.test.espresso.util.HumanReadables",
            "import androidx.test.espresso.util.TreeIterables",
            "import org.hamcrest.Description",
            "import org.hamcrest.Matcher"
        ]
        let sorted = (fixed + sharedFunctions + optional + helperImports + gestureHelperImports).sorted()
        return (sorted + (contextImports.isEmpty ? [] : [contextImports])).joined(separator: "\n")
    }

    static let standaloneLaunch = """
            val targetContext = InstrumentationRegistry.getInstrumentation().targetContext
            val launchIntent = requireNotNull(
                targetContext.packageManager.getLaunchIntentForPackage(targetContext.packageName)
            ) { "No launcher activity found for ${targetContext.packageName}" }
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)

            ActivityScenario.launch<Activity>(launchIntent).use {
    """

    static let sharedLaunch = "        launchTargetApp().use {"
}
