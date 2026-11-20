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
            compose.onNode(hasTestTag("fixture-disabled-action")).assertIsNotEnabled()
            compose.onNode(hasTestTag("fixture-open-details")).performClick()
            compose.onNode(hasTestTag("fixture-detail-row-0")).assertIsDisplayed()
            compose.onNode(hasTestTag("fixture-details-tail")).performScrollTo().assertIsDisplayed()
            compose.onNode(hasTestTag("fixture-details-back")).performScrollTo().performClick()
            compose.onNode(hasTestTag("fixture-home-title")).assertIsDisplayed()
        }
    }

    @Test
    fun detailsHasABackControlAtTheTopThatNeedsNoScroll() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture-open-details")).performClick()
            compose.onNode(hasTestTag("fixture-details-back-top")).assertIsDisplayed().performClick()
            compose.onNode(hasTestTag("fixture-home-title")).assertIsDisplayed()
        }
    }

    @Test
    fun textInputEchoesEditsAndClears() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture-open-text")).performClick()
            compose.onNode(hasText("Hello from the fixture app")).assertIsDisplayed()
            compose.onNode(hasTestTag("fixture-text-input")).performTextInput("contract text")
            compose.onNode(hasTestTag("fixture-text-echo")).assertTextEquals("Echo: contract text")
            compose.onNode(hasTestTag("fixture-text-input")).performTextReplacement("")
            compose.onNode(hasTestTag("fixture-text-echo")).assertTextEquals("Echo: ")
        }
    }

    @Test
    fun gesturePadRespondsToTaps() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.onNode(hasTestTag("fixture-open-gesture")).performClick()
            compose.onNode(hasText("Gesture Pad")).assertIsDisplayed().performClick()
            compose.onNode(hasTestTag("fixture-tap-count")).assertTextEquals("Tap count: 1")
            compose.onNode(hasTestTag("fixture-gesture-pad")).performClick()
            compose.onNode(hasTestTag("fixture-tap-count")).assertTextEquals("Tap count: 2")
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
            compose.onNode(hasTestTag("fixture-home-title")).assertIsDisplayed()
        }
    }
}
