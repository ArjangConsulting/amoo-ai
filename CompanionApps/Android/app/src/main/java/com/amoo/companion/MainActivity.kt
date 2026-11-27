package com.amoo.companion

import android.app.Activity
import android.content.Intent
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
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
    CONFIRMATION,
    AUDIT,
    AUDIT_CLEAN
}

class MainActivity : Activity() {
    private val defaultTextValue = "Hello from the fixture app"
    private val defaultDeepLinkValue = "No URL opened yet"
    private val screenStack = mutableListOf(FixtureScreen.HOME)
    private var textValue: String = defaultTextValue
    private var tapCount = 0
    private var doubleTapCount = 0
    private var longPressState = "idle"
    private var deepLinkValue = defaultDeepLinkValue
    private var lastTapTimestamp = 0L
    private val primaryForegroundColor: ColorStateList? by lazy {
        val attributes = obtainStyledAttributes(intArrayOf(android.R.attr.textColorPrimary))
        try {
            attributes.getColorStateList(0)
        } finally {
            attributes.recycle()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) {
            handleIntent(intent)
        } else {
            restoreState(savedInstanceState)
        }
        renderCurrentScreen()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putStringArrayList(STATE_SCREEN_STACK, ArrayList(screenStack.map { it.name }))
        outState.putString(STATE_TEXT_VALUE, textValue)
        outState.putInt(STATE_TAP_COUNT, tapCount)
        outState.putInt(STATE_DOUBLE_TAP_COUNT, doubleTapCount)
        outState.putString(STATE_LONG_PRESS, longPressState)
        outState.putString(STATE_DEEP_LINK, deepLinkValue)
    }

    private fun restoreState(state: Bundle) {
        val restoredStack = state.getStringArrayList(STATE_SCREEN_STACK)
            .orEmpty()
            .mapNotNull { name -> FixtureScreen.entries.firstOrNull { it.name == name } }
        if (restoredStack.isNotEmpty()) {
            screenStack.clear()
            screenStack += restoredStack
        }
        textValue = state.getString(STATE_TEXT_VALUE, defaultTextValue)
        tapCount = state.getInt(STATE_TAP_COUNT)
        doubleTapCount = state.getInt(STATE_DOUBLE_TAP_COUNT)
        longPressState = state.getString(STATE_LONG_PRESS, "idle")
        deepLinkValue = state.getString(STATE_DEEP_LINK, defaultDeepLinkValue)
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
        if (data.scheme != "amoo") {
            return
        }

        val normalizedURL = data.toString().lowercase()
        if (normalizedURL.startsWith("amoo://home") || normalizedURL.startsWith("amoo://reset")) {
            resetFixtureState()
            navigateTo(FixtureScreen.HOME, replaceStack = true)
            return
        }

        when (routeFor(data)) {
            "audit" -> navigateTo(FixtureScreen.AUDIT, replaceStack = true)
            "audit-clean" -> navigateTo(FixtureScreen.AUDIT_CLEAN, replaceStack = true)
            "home", "reset" -> {
                resetFixtureState()
                navigateTo(FixtureScreen.HOME, replaceStack = true)
            }
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

    private fun routeFor(data: Uri): String? {
        val rawRoute = data.toString()
            .removePrefix("amoo://")
            .trimStart('/')
            .substringBefore('?')
            .substringBefore('#')
            .substringBefore('/')

        return sequenceOf(
            data.host,
            data.authority,
            data.pathSegments.firstOrNull(),
            data.lastPathSegment,
            data.schemeSpecificPart
                ?.removePrefix("//")
                ?.substringBefore('?')
                ?.substringBefore('#')
                ?.substringBefore('/'),
            rawRoute,
        )
            .mapNotNull { it?.takeIf(String::isNotBlank) }
            .firstOrNull()
    }

    private fun resetFixtureState() {
        screenStack.clear()
        screenStack += FixtureScreen.HOME
        textValue = defaultTextValue
        tapCount = 0
        doubleTapCount = 0
        longPressState = "idle"
        deepLinkValue = defaultDeepLinkValue
        lastTapTimestamp = 0L
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
        val root = ScrollView(this)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val horizontal = resources.getDimensionPixelSize(R.dimen.fixture_screen_padding)
            setPadding(
                horizontal,
                horizontal,
                horizontal,
                resources.getDimensionPixelSize(R.dimen.fixture_screen_padding_bottom),
            )
        }

        when (screenStack.last()) {
            FixtureScreen.AUDIT -> AccessibilityFixture.addTo(this, content, defects = true)
            FixtureScreen.AUDIT_CLEAN -> AccessibilityFixture.addTo(this, content, defects = false)
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
        parent.addView(titleView("Fixture Home", R.id.fixture_home_title))
        parent.addView(bodyView("Home screen ready for contract tests", R.id.fixture_home_screen))

        parent.addView(sectionLabel("Launch Targets"))
        parent.addView(navButton("Open Details", R.id.fixture_open_details) { navigateTo(FixtureScreen.DETAILS) })
        parent.addView(navButton("Open Text Input", R.id.fixture_open_text) { navigateTo(FixtureScreen.TEXT) })
        parent.addView(navButton("Open Gesture Lab", R.id.fixture_open_gesture) { navigateTo(FixtureScreen.GESTURE) })
        parent.addView(navButton("Open Permissions", R.id.fixture_open_permissions) { navigateTo(FixtureScreen.PERMISSIONS) })
        parent.addView(navButton("Open Appearance", R.id.fixture_open_appearance) { navigateTo(FixtureScreen.APPEARANCE) })
        parent.addView(navButton("Open Deep Link", R.id.fixture_open_deeplink) { navigateTo(FixtureScreen.DEEP_LINK) })
        parent.addView(navButton("Open Confirmation", R.id.fixture_open_confirmation) { navigateTo(FixtureScreen.CONFIRMATION) })

        parent.addView(sectionLabel("Gesture Summary"))
        parent.addView(bodyView("Tap count: $tapCount", R.id.fixture_tap_count))
        parent.addView(bodyView("Double tap count: $doubleTapCount", R.id.fixture_double_tap_count))
        parent.addView(bodyView("Long press: $longPressState", R.id.fixture_long_press_status))
    }

    private fun renderDetails(parent: LinearLayout) {
        parent.addView(titleView("Details", R.id.fixture_details_screen))
        for (index in 0 until 30) {
            parent.addView(bodyView("Fixture row $index", detailRowIDs[index]))
        }
        parent.addView(bodyView("Details tail marker", R.id.fixture_details_tail))
    }

    private fun renderText(parent: LinearLayout) {
        parent.addView(titleView("Text Input", R.id.fixture_text_screen))

        val textValueLabel = bodyView("Current text: $textValue", R.id.fixture_text_value)

        val inputLabel = TextView(this).apply {
            text = "Fixture Input"
            id = R.id.fixture_text_input_label
            labelFor = R.id.fixture_text_input
            primaryForegroundColor?.let(::setTextColor)
        }

        val input = EditText(this).apply {
            hint = "Fixture Input"
            setText(textValue)
            id = R.id.fixture_text_input
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(s: Editable?) {
                    textValue = s?.toString().orEmpty()
                    textValueLabel.text = "Current text: $textValue"
                }
            })
        }

        parent.addView(inputLabel)
        parent.addView(input, matchWidthParams())
        parent.addView(textValueLabel)
    }

    private fun renderGesture(parent: LinearLayout) {
        parent.addView(titleView("Gesture Lab", R.id.fixture_gesture_screen))

        val pad = TextView(this).apply {
            text = "Gesture Pad"
            textSize = 24f
            gravity = Gravity.CENTER
            setTypeface(typeface, Typeface.BOLD)
            id = R.id.fixture_gesture_pad
            setBackgroundColor(getColor(R.color.fixture_gesture_pad))
            setTextColor(Color.WHITE)
            setPadding(
                resources.getDimensionPixelSize(R.dimen.fixture_gesture_pad_horizontal),
                resources.getDimensionPixelSize(R.dimen.fixture_gesture_pad_vertical),
                resources.getDimensionPixelSize(R.dimen.fixture_gesture_pad_horizontal),
                resources.getDimensionPixelSize(R.dimen.fixture_gesture_pad_vertical),
            )
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
        parent.addView(bodyView("Scroll target", R.id.fixture_gesture_scroll_target))
        for (index in 0 until 10) {
            parent.addView(bodyView("Gesture item $index", gestureItemIDs[index]))
        }
    }

    private fun renderPermissions(parent: LinearLayout) {
        parent.addView(titleView("Permissions Screen", R.id.fixture_permissions_screen))
        parent.addView(bodyView("Use host commands to grant camera, notifications, or location.", R.id.fixture_permissions_message))
    }

    private fun renderAppearance(parent: LinearLayout) {
        parent.addView(titleView("Appearance Screen", R.id.fixture_appearance_screen))
        parent.addView(bodyView(currentAppearance(), R.id.fixture_appearance_value))
    }

    private fun renderDeepLink(parent: LinearLayout) {
        parent.addView(titleView("Deep Link Screen", R.id.fixture_deeplink_screen))
        parent.addView(bodyView(deepLinkValue, R.id.fixture_deeplink_value))
    }

    private fun renderConfirmation(parent: LinearLayout) {
        parent.addView(titleView("Confirmation Screen", R.id.fixture_confirmation_screen))
        parent.addView(bodyView("The fixture app reached its confirmation state.", R.id.fixture_confirmation_message))
    }

    private fun sectionLabel(text: String): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 18f
            primaryForegroundColor?.let(::setTextColor)
            setTypeface(typeface, Typeface.BOLD)
            setPadding(
                0,
                resources.getDimensionPixelSize(R.dimen.fixture_section_label_top),
                0,
                resources.getDimensionPixelSize(R.dimen.fixture_section_label_bottom),
            )
            markAsHeading(this)
        }
    }

    private fun titleView(text: String, id: Int): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 30f
            primaryForegroundColor?.let(::setTextColor)
            setTypeface(typeface, Typeface.BOLD)
            this.id = id
            markAsHeading(this)
        }
    }

    private fun bodyView(text: String, id: Int): TextView {
        return TextView(this).apply {
            this.text = text
            textSize = 18f
            primaryForegroundColor?.let(::setTextColor)
            setPadding(0, 0, 0, resources.getDimensionPixelSize(R.dimen.fixture_body_bottom))
            this.id = id
        }
    }

    private fun navButton(label: String, id: Int, onClick: () -> Unit): Button {
        return Button(this).apply {
            text = label
            this.id = id
            setOnClickListener { onClick() }
        }
    }

    private fun markAsHeading(view: View) {
        if (Build.VERSION.SDK_INT >= 28) {
            view.isAccessibilityHeading = true
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
            bottomMargin = resources.getDimensionPixelSize(R.dimen.fixture_field_bottom_margin)
        }
    }

    private companion object {
        const val STATE_SCREEN_STACK = "screen_stack"
        const val STATE_TEXT_VALUE = "text_value"
        const val STATE_TAP_COUNT = "tap_count"
        const val STATE_DOUBLE_TAP_COUNT = "double_tap_count"
        const val STATE_LONG_PRESS = "long_press_state"
        const val STATE_DEEP_LINK = "deep_link_value"

        val detailRowIDs = intArrayOf(
            R.id.fixture_detail_row_0,
            R.id.fixture_detail_row_1,
            R.id.fixture_detail_row_2,
            R.id.fixture_detail_row_3,
            R.id.fixture_detail_row_4,
            R.id.fixture_detail_row_5,
            R.id.fixture_detail_row_6,
            R.id.fixture_detail_row_7,
            R.id.fixture_detail_row_8,
            R.id.fixture_detail_row_9,
            R.id.fixture_detail_row_10,
            R.id.fixture_detail_row_11,
            R.id.fixture_detail_row_12,
            R.id.fixture_detail_row_13,
            R.id.fixture_detail_row_14,
            R.id.fixture_detail_row_15,
            R.id.fixture_detail_row_16,
            R.id.fixture_detail_row_17,
            R.id.fixture_detail_row_18,
            R.id.fixture_detail_row_19,
            R.id.fixture_detail_row_20,
            R.id.fixture_detail_row_21,
            R.id.fixture_detail_row_22,
            R.id.fixture_detail_row_23,
            R.id.fixture_detail_row_24,
            R.id.fixture_detail_row_25,
            R.id.fixture_detail_row_26,
            R.id.fixture_detail_row_27,
            R.id.fixture_detail_row_28,
            R.id.fixture_detail_row_29,
        )

        val gestureItemIDs = intArrayOf(
            R.id.fixture_gesture_item_0,
            R.id.fixture_gesture_item_1,
            R.id.fixture_gesture_item_2,
            R.id.fixture_gesture_item_3,
            R.id.fixture_gesture_item_4,
            R.id.fixture_gesture_item_5,
            R.id.fixture_gesture_item_6,
            R.id.fixture_gesture_item_7,
            R.id.fixture_gesture_item_8,
            R.id.fixture_gesture_item_9,
        )
    }
}
