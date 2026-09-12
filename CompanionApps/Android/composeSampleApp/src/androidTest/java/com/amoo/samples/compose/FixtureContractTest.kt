package com.amoo.samples.compose

import android.content.Intent
import android.net.Uri
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Exercises the fixture contract independently of the companion's gRPC transport. */
@RunWith(AndroidJUnit4::class)
class FixtureContractTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @Test
    fun detailsCanScrollToTailAndReturnHome() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture_disabled_action")).assertIsNotEnabled()
            compose.onNode(hasTestTag("fixture_open_details")).performClick()
            compose.onNode(hasTestTag("fixture_detail_row_0")).assertIsDisplayed()
            compose.onNode(hasTestTag("fixture_details_tail")).performScrollTo().assertIsDisplayed()
            compose.onNode(hasTestTag("fixture_details_back")).performScrollTo().performClick()
            compose.onNode(hasTestTag("fixture_home_title")).assertIsDisplayed()
        }
    }

    @Test
    fun textInputEchoesEditsAndClears() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture_open_text")).performClick()
            compose.onNode(hasText("Hello from the fixture app")).assertIsDisplayed()
            compose.onNode(hasTestTag("fixture_text_input")).performTextInput("contract text")
            compose.onNode(hasTestTag("fixture_text_echo")).assertTextEquals("Echo: contract text")
            compose.onNode(hasTestTag("fixture_text_input")).performTextReplacement("")
            compose.onNode(hasTestTag("fixture_text_echo")).assertTextEquals("Echo: ")
        }
    }

    @Test
    fun gesturePadRespondsToTaps() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture_open_gesture")).performClick()
            compose.onNode(hasText("Gesture Pad")).assertIsDisplayed().performClick()
            compose.onNode(hasTestTag("fixture_tap_count")).assertTextEquals("Tap count: 1")
            compose.onNode(hasTestTag("fixture_gesture_pad")).performClick()
            compose.onNode(hasTestTag("fixture_tap_count")).assertTextEquals("Tap count: 2")
        }
    }

    @Test
    fun deepLinkResolvesToFixtureAndDisplaysFullURL() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val url = "amoo-compose://deep-link?source=contract"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        assertEquals(context.packageName, intent.resolveActivity(context.packageManager)?.packageName)
        ActivityScenario.launch<MainActivity>(intent).use {
            compose.onNode(hasText(url)).assertIsDisplayed()
            compose.onNode(hasTestTag("fixture_home_title")).assertIsDisplayed()
        }
    }
}
