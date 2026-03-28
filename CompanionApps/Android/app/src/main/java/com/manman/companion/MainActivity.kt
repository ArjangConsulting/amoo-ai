package com.manman.companion

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

private enum class FixtureScreen {
    HOME,
    DETAILS,
    TEXT,
    GESTURE,
    PERMISSIONS,
    APPEARANCE,
    DEEP_LINK,
    CONFIRMATION
}

class MainActivity : Activity() {
    private val screenStack = mutableListOf(FixtureScreen.HOME)
    private var textValue: String = "Hello from the fixture app"
    private var tapCount = 0
    private var doubleTapCount = 0
    private var longPressState = "idle"
    private var deepLinkValue = "No URL opened yet"
    private var lastTapTimestamp = 0L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
        renderCurrentScreen()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
        renderCurrentScreen()
    }

    override fun onBackPressed() {
        if (screenStack.size > 1) {
            screenStack.removeAt(screenStack.lastIndex)
            renderCurrentScreen()
        } else {
            super.onBackPressed()
        }
    }

    private fun handleIntent(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "mobile-testing") {
            return
        }

        when (data.host) {
            "details" -> navigateTo(FixtureScreen.DETAILS, replaceStack = true)
            "text" -> navigateTo(FixtureScreen.TEXT, replaceStack = true)
            "gesture" -> navigateTo(FixtureScreen.GESTURE, replaceStack = true)
            "permissions" -> navigateTo(FixtureScreen.PERMISSIONS, replaceStack = true)
            "appearance" -> navigateTo(FixtureScreen.APPEARANCE, replaceStack = true)
            "confirm" -> navigateTo(FixtureScreen.CONFIRMATION, replaceStack = true)
            else -> {
                deepLinkValue = data.toString()
                navigateTo(FixtureScreen.DEEP_LINK, replaceStack = true)
            }
        }
    }

    private fun navigateTo(screen: FixtureScreen, replaceStack: Boolean = false) {
        if (replaceStack) {
            screenStack.clear()
            screenStack += FixtureScreen.HOME
        }
        if (screenStack.lastOrNull() != screen) {
            screenStack += screen
        }
        renderCurrentScreen()
    }

    private fun renderCurrentScreen() {
        val root = ScrollView(this).apply {
            setBackgroundColor(Color.WHITE)
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 72)
        }

        when (screenStack.last()) {
            FixtureScreen.HOME -> renderHome(content)
            FixtureScreen.DETAILS -> renderDetails(content)
            FixtureScreen.TEXT -> renderText(content)
            FixtureScreen.GESTURE -> renderGesture(content)
            FixtureScreen.PERMISSIONS -> renderPermissions(content)
            FixtureScreen.APPEARANCE -> renderAppearance(content)
            FixtureScreen.DEEP_LINK -> renderDeepLink(content)
            FixtureScreen.CONFIRMATION -> renderConfirmation(content)
        }

        root.addView(content)
        setContentView(root)
    }

    private fun renderHome(parent: LinearLayout) {
        parent.addView(titleView("Fixture Home", "fixture-home-title"))
        parent.addView(bodyView("Home screen ready for contract tests", "fixture-home-screen"))

        parent.addView(sectionLabel("Launch Targets"))
        parent.addView(navButton("Open Details", "fixture-open-details") { navigateTo(FixtureScreen.DETAILS) })
        parent.addView(navButton("Open Text Input", "fixture-open-text") { navigateTo(FixtureScreen.TEXT) })
        parent.addView(navButton("Open Gesture Lab", "fixture-open-gesture") { navigateTo(FixtureScreen.GESTURE) })
        parent.addView(navButton("Open Permissions", "fixture-open-permissions") { navigateTo(FixtureScreen.PERMISSIONS) })
        parent.addView(navButton("Open Appearance", "fixture-open-appearance") { navigateTo(FixtureScreen.APPEARANCE) })
        parent.addView(navButton("Open Deep Link", "fixture-open-deeplink") { navigateTo(FixtureScreen.DEEP_LINK) })
        parent.addView(navButton("Open Confirmation", "fixture-open-confirmation") { navigateTo(FixtureScreen.CONFIRMATION) })

        parent.addView(sectionLabel("Gesture Summary"))
        parent.addView(bodyView("Tap count: $tapCount", "fixture-tap-count"))
        parent.addView(bodyView("Double tap count: $doubleTapCount", "fixture-double-tap-count"))
        parent.addView(bodyView("Long press: $longPressState", "fixture-long-press-status"))
    }

    private fun renderDetails(parent: LinearLayout) {
        parent.addView(titleView("Details", "fixture-details-screen"))
        for (index in 0 until 30) {
            parent.addView(bodyView("Fixture row $index", "fixture-detail-row-$index"))
        }
        parent.addView(bodyView("Details tail marker", "fixture-details-tail"))
    }

    private fun renderText(parent: LinearLayout) {
        parent.addView(titleView("Text Input", "fixture-text-screen"))

        val input = EditText(this).apply {
            hint = "Fixture Input"
            setText(textValue)
            contentDescription = "fixture-text-input"
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    textValue = s?.toString().orEmpty()
                    renderCurrentScreen()
                }
            })
        }

        parent.addView(input, matchWidthParams())
        parent.addView(bodyView(textValue, "fixture-text-value"))
    }

    private fun renderGesture(parent: LinearLayout) {
        parent.addView(titleView("Gesture Lab", "fixture-gesture-screen"))

        val pad = TextView(this).apply {
            text = "Gesture Pad"
            textSize = 24f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            setBackgroundColor(Color.parseColor("#F97316"))
            setTextColor(Color.WHITE)
            contentDescription = "fixture-gesture-pad"
            setPadding(24, 120, 24, 120)
            setOnClickListener {
                val now = System.currentTimeMillis()
                tapCount += 1
                if (now - lastTapTimestamp < 350) {
                    doubleTapCount += 1
                }
                lastTapTimestamp = now
                renderCurrentScreen()
            }
            setOnLongClickListener {
                longPressState = "completed"
                renderCurrentScreen()
                true
            }
        }
        parent.addView(pad, matchWidthParams())
        parent.addView(bodyView("Scroll target", "fixture-gesture-scroll-target"))
        for (index in 0 until 10) {
            parent.addView(bodyView("Gesture item $index", "fixture-gesture-item-$index"))
        }
    }

    private fun renderPermissions(parent: LinearLayout) {
        parent.addView(titleView("Permissions Screen", "fixture-permissions-screen"))
        parent.addView(bodyView("Use host commands to grant camera, notifications, or location.", "fixture-permissions-message"))
    }

    private fun renderAppearance(parent: LinearLayout) {
        parent.addView(titleView("Appearance Screen", "fixture-appearance-screen"))
        parent.addView(bodyView(currentAppearance(), "fixture-appearance-value"))
    }

    private fun renderDeepLink(parent: LinearLayout) {
        parent.addView(titleView("Deep Link Screen", "fixture-deeplink-screen"))
        parent.addView(bodyView(deepLinkValue, "fixture-deeplink-value"))
    }

    private fun renderConfirmation(parent: LinearLayout) {
        parent.addView(titleView("Confirmation Screen", "fixture-confirmation-screen"))
        parent.addView(bodyView("The fixture app reached its confirmation state.", "fixture-confirmation-message"))
    }

    private fun sectionLabel(text: String): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, 32, 0, 16)
        }
    }

    private fun titleView(text: String, id: String): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 30f
            setTypeface(typeface, Typeface.BOLD)
            contentDescription = id
        }
    }

    private fun bodyView(text: String, id: String): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 18f
            setPadding(0, 0, 0, 16)
            contentDescription = id
        }
    }

    private fun navButton(label: String, id: String, onClick: () -> Unit): Button {
        return Button(this).apply {
            text = label
            contentDescription = id
            setOnClickListener { onClick() }
        }
    }

    private fun currentAppearance(): String {
        return if ((resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES) {
            "dark"
        } else {
            "light"
        }
    }

    private fun matchWidthParams(): LinearLayout.LayoutParams {
        return LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply {
            bottomMargin = 16
        }
    }
}
