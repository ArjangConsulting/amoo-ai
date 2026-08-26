package com.amoo.samples.compose

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp

/**
 * Fixture app under test for a Jetpack Compose UI.
 *
 * Mirrors a subset of the classic-View fixture in the companion app (`com.amoo.companion`), so the
 * same recorded flows can be compared across toolkits. It is deliberately a *separate installable
 * app*: the companion drives it from its own process over the accessibility tree, which is what
 * makes it a real test of the driver rather than of an in-process harness.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { SampleApp() }
    }
}

private enum class Screen { HOME, DETAILS, TEXT_INPUT, GESTURE }

@Composable
private fun SampleApp() {
    var screen by remember { mutableStateOf(Screen.HOME) }

    MaterialTheme {
        Surface(
            modifier = Modifier
                .fillMaxSize()
                // Without this, Compose testTags are invisible to UiAutomator: Compose exposes
                // them only to its own semantics tree unless they are also published as resource
                // ids. amoo's Android driver is UiAutomator-based, so every id-based selector it
                // records would otherwise come back empty against a Compose screen.
                .semantics { testTagsAsResourceId = true }
        ) {
            when (screen) {
                Screen.HOME -> HomeScreen(onNavigate = { screen = it })
                Screen.DETAILS -> DetailsScreen(onBack = { screen = Screen.HOME })
                Screen.TEXT_INPUT -> TextInputScreen(onBack = { screen = Screen.HOME })
                Screen.GESTURE -> GestureScreen(onBack = { screen = Screen.HOME })
            }
        }
    }
}

@Composable
private fun HomeScreen(onNavigate: (Screen) -> Unit) {
    Column(modifier = Modifier.padding(16.dp)) {
        Text(
            text = "Compose Fixture Home",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier
                .testTag("fixture_home_title")
                .semantics { contentDescription = "fixture-home-title" }
        )
        Text(
            text = "Home screen ready for contract tests",
            modifier = Modifier.semantics { contentDescription = "fixture-home-screen" }
        )
        Button(
            onClick = { onNavigate(Screen.DETAILS) },
            modifier = Modifier
                .testTag("fixture_open_details")
                .semantics { contentDescription = "fixture-open-details" }
        ) { Text("Open Details") }
        Button(
            onClick = { onNavigate(Screen.TEXT_INPUT) },
            modifier = Modifier
                .testTag("fixture_open_text")
                .semantics { contentDescription = "fixture-open-text" }
        ) { Text("Open Text Input") }
        Button(
            onClick = { onNavigate(Screen.GESTURE) },
            modifier = Modifier
                .testTag("fixture_open_gesture")
                .semantics { contentDescription = "fixture-open-gesture" }
        ) { Text("Open Gesture Lab") }
        // Deliberately disabled: gives assert_enabled something that must fail when pointed here,
        // so the assertion is proven to actually assert rather than always passing.
        Button(
            onClick = {},
            enabled = false,
            modifier = Modifier
                .testTag("fixture_disabled_action")
                .semantics { contentDescription = "fixture-disabled-action" }
        ) { Text("Disabled Action") }
    }
}

@Composable
private fun DetailsScreen(onBack: () -> Unit) {
    Column(
        modifier = Modifier
            .padding(16.dp)
            .verticalScroll(rememberScrollState())
    ) {
        Text(
            text = "Details",
            modifier = Modifier.semantics { contentDescription = "fixture-details-screen" }
        )
        // Enough rows to push the last one below the fold, so a scroll is genuinely required to
        // reach it — this is what makes a dropped `scroll` step observable rather than harmless.
        repeat(20) { index ->
            Text(
                text = "Fixture row $index",
                modifier = Modifier
                    .testTag("fixture_detail_row_$index")
                    .semantics { contentDescription = "fixture-detail-row-$index" }
            )
        }
        Button(
            onClick = onBack,
            modifier = Modifier
                .testTag("fixture_details_back")
                .semantics { contentDescription = "fixture-details-back" }
        ) { Text("Back") }
    }
}

@Composable
private fun TextInputScreen(onBack: () -> Unit) {
    var value by remember { mutableStateOf("") }

    Column(modifier = Modifier.padding(16.dp)) {
        Text(
            text = "Text Input",
            modifier = Modifier.semantics { contentDescription = "fixture-text-screen" }
        )
        TextField(
            value = value,
            onValueChange = { value = it },
            modifier = Modifier
                .testTag("fixture_text_field")
                .semantics { contentDescription = "fixture-text-field" }
        )
        Text(
            text = "Echo: $value",
            modifier = Modifier
                .testTag("fixture_text_echo")
                .semantics { contentDescription = "fixture-text-echo" }
        )
        Button(
            onClick = onBack,
            modifier = Modifier
                .testTag("fixture_text_back")
                .semantics { contentDescription = "fixture-text-back" }
        ) { Text("Back") }
    }
}

@Composable
private fun GestureScreen(onBack: () -> Unit) {
    var taps by remember { mutableStateOf(0) }

    Column(modifier = Modifier.padding(16.dp)) {
        Text(
            text = "Gesture Lab",
            modifier = Modifier.semantics { contentDescription = "fixture-gesture-screen" }
        )
        Button(
            onClick = { taps += 1 },
            modifier = Modifier
                .testTag("fixture_tap_target")
                .semantics { contentDescription = "fixture-tap-target" }
        ) { Text("Tap Target") }
        Text(
            text = "Tap count: $taps",
            modifier = Modifier
                .testTag("fixture_tap_count")
                .semantics { contentDescription = "fixture-tap-count" }
        )
        Button(
            onClick = onBack,
            modifier = Modifier
                .testTag("fixture_gesture_back")
                .semantics { contentDescription = "fixture-gesture-back" }
        ) { Text("Back") }
    }
}
