package com.amoo.samples.compose

import android.content.ClipData
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.graphics.Color
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
    private var deepLink by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        deepLink = intent?.dataString
        setContent { SampleApp(deepLink) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        deepLink = intent.dataString
    }
}

private enum class Screen { HOME, DETAILS, TEXT_INPUT, GESTURE }

@Composable
private fun SampleApp(deepLink: String?) {
    var screen by remember { mutableStateOf(Screen.HOME) }

    // System back leaves a sub-screen for Home. Home itself keeps the default, which exits the app,
    // so a test that presses back on Home leaves the app by design: drivers must not do that.
    BackHandler(enabled = screen != Screen.HOME) { screen = Screen.HOME }

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
                Screen.HOME -> HomeScreen(deepLink = deepLink, onNavigate = { screen = it })
                Screen.DETAILS -> DetailsScreen(onBack = { screen = Screen.HOME })
                Screen.TEXT_INPUT -> TextInputScreen(onBack = { screen = Screen.HOME })
                Screen.GESTURE -> GestureScreen(onBack = { screen = Screen.HOME })
            }
        }
    }
}

@Composable
private fun HomeScreen(deepLink: String?, onNavigate: (Screen) -> Unit) {
    Column(modifier = Modifier.padding(16.dp)) {
        deepLink?.let { Text(text = it) }
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
        // Reachable without scrolling, so leaving Details never needs the 30 rows below to be crossed.
        Button(
            onClick = onBack,
            modifier = Modifier
                .testTag("fixture_details_back_top")
                .semantics { contentDescription = "fixture-details-back-top" }
        ) { Text("Back") }
        Text(
            text = "Details",
            modifier = Modifier.semantics { contentDescription = "fixture-details-screen" }
        )
        // Enough rows to push the last one below the fold, so a scroll is genuinely required to
        // reach it — this is what makes a dropped `scroll` step observable rather than harmless.
        repeat(30) { index ->
            Text(
                text = "Fixture row $index",
                modifier = Modifier
                    .heightIn(min = 48.dp)
                    .testTag("fixture_detail_row_$index")
                    .semantics { contentDescription = "fixture-detail-row-$index" }
            )
        }
        Text(
            text = "Details tail marker",
            modifier = Modifier
                .testTag("fixture_details_tail")
                .semantics { contentDescription = "fixture-details-tail" }
        )
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
            placeholder = { Text("Hello from the fixture app") },
            modifier = Modifier
                .testTag("fixture_text_input")
                .semantics { contentDescription = "fixture-text-input" }
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
                .heightIn(min = 200.dp)
                .testTag("fixture_gesture_pad")
                .semantics { contentDescription = "fixture-gesture-pad" }
        ) { Text("Gesture Pad") }
        Text(
            text = "Tap count: $taps",
            modifier = Modifier
                .testTag("fixture_tap_count")
                .semantics { contentDescription = "fixture-tap-count" }
        )
        DragDropRow()
        PinchTarget()
        Button(
            onClick = onBack,
            modifier = Modifier
                .testTag("fixture_gesture_back")
                .semantics { contentDescription = "fixture-gesture-back" }
        ) { Text("Back") }
    }
}

/** A system drag-and-drop source and drop zone; the card starts a drag only on long press. */
@Composable
private fun DragDropRow() {
    var dropState by remember { mutableStateOf("empty") }
    val target = remember {
        object : DragAndDropTarget {
            override fun onDrop(event: DragAndDropEvent): Boolean {
                dropState = "dropped"
                return true
            }
        }
    }
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .weight(1f)
                .height(100.dp)
                .background(Color(0xFFE9D5FF))
                .dragAndDropSource { _ ->
                    DragAndDropTransferData(ClipData.newPlainText("fixture", "fixture-card"))
                }
                .testTag("fixture_drag_source")
                .semantics { contentDescription = "fixture-drag-source" }
        ) { Text("Drag Card") }
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .weight(1f)
                .height(100.dp)
                .background(Color(0xFFBBF7D0))
                .dragAndDropTarget(shouldStartDragAndDrop = { true }, target = target)
                .testTag("fixture_drop_zone")
                .semantics { contentDescription = "fixture-drop-zone" }
        ) { Text(if (dropState == "dropped") "Dropped" else "Drop Zone") }
    }
    Text(
        text = "Drop state: $dropState",
        modifier = Modifier
            .testTag("fixture_drop_state")
            .semantics { contentDescription = "fixture-drop-state" }
    )
}

/** Reports the direction of the last completed pinch, so a test can tell zoom in from zoom out. */
@Composable
private fun PinchTarget() {
    var lastPinch by remember { mutableStateOf("none") }
    var cumulative by remember { mutableStateOf(1f) }
    val state = rememberTransformableState { zoomChange, _, _ -> cumulative *= zoomChange }
    LaunchedEffect(state.isTransformInProgress) {
        if (!state.isTransformInProgress && cumulative != 1f) {
            lastPinch = if (cumulative > 1f) "in" else "out"
            cumulative = 1f
        }
    }
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .height(180.dp)
            .background(Color(0xFFCCFBF1))
            .transformable(state)
            .testTag("fixture_pinch_target")
            .semantics { contentDescription = "fixture-pinch-target" }
    ) { Text("Pinch Target") }
    Text(
        text = "Last pinch: $lastPinch",
        modifier = Modifier
            .testTag("fixture_pinch_state")
            .semantics { contentDescription = "fixture-pinch-state" }
    )
}
