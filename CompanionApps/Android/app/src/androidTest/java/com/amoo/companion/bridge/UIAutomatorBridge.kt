package com.amoo.companion.bridge

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.Configurator
import android.app.UiAutomation
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.uiautomator.By
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import java.io.ByteArrayOutputStream
import java.util.regex.Pattern
import kotlin.math.roundToInt

/**
 * Single point of contact with Android's UIAutomator2 framework.
 * If UIAutomator APIs change, only this file changes.
 */
class UIAutomatorBridge {
    private val hierarchyCapture = HierarchyCapture()
    private companion object {
        /** Gap between injected ACTION_MOVE events during a drag, in milliseconds. */
        const val MOVE_INTERVAL_MS = 10

        /** Dwell at the destination before lifting, so drop targets see the drag finish. */
        const val DROP_SETTLE_MS = 200L

        /** Travel time of a scroll's eased drag, matching the iOS companion. */
        const val SCROLL_DURATION_MS = 400

        /**
         * Rest before a scroll lifts. Longer than VelocityTracker's 40 ms stopped-pointer window,
         * so the release carries no velocity and the list stops where the finger did.
         */
        const val SCROLL_SETTLE_MS = 60L

        /** A scroll never travels more than this share of the screen, matching the iOS companion. */
        const val SCROLL_MAX_EXTENT = 0.7

        /**
         * How far up the tree to look for a clickable ancestor. Compose nests a matched semantics
         * node only a few levels under its clickable owner; a larger bound would start returning
         * whole screens as tap targets.
         */
        const val MAX_ANCESTOR_WALK = 5

        /** Bounds the accessibility walk so a pathological tree cannot stall a query. */
        const val MAX_TREE_DEPTH = 60

        /** Quiescence wait before reading the hierarchy, so a mid-transition frame is not captured. */
        const val WAIT_FOR_IDLE_MS = 2_000L

        /** How long `setText` waits for a field to show the value it was given. */
        const val SET_TEXT_SETTLE_MS = 1_000L

        /** How long one capture may spend inside a WebView's subtree before it stops descending. */
        const val WEBVIEW_SUBTREE_BUDGET_MS = 1_500L

        const val LOG_TAG = "AmooCompanion"

        /** Matches any application package, used to force a full multi-window root walk. */
        val ANY_PACKAGE: Pattern = Pattern.compile(".+")
    }

    // Netty may deliver the first two RPCs concurrently, so initialization must be serialized too.
    private val instrumentation by lazy {
        InstrumentationRegistry.getInstrumentation()
    }
    private val device by lazy {
        Configurator.getInstance().uiAutomationFlags = UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES
        Configurator.getInstance().toolType = MotionEvent.TOOL_TYPE_FINGER
        Configurator.getInstance().waitForIdleTimeout = 200
        UiDevice.getInstance(instrumentation).also { enableInteractiveWindowRetrieval() }
    }
    private val targetPackageName by lazy {
        instrumentation.targetContext.packageName
    }

    // There is deliberately no element cache here, unlike the iOS bridge.
    //
    // One was tried and removed. Measured on a booted emulator against a sample app, a single
    // `find_elements` costs ~2.7s — the cache's 150ms TTL had expired roughly eighteen times over
    // before any second query could arrive, so it never once served a hit. Before/after numbers
    // were identical (2.73s vs 2.69s), and all it added was live `UiObject2` handles held across
    // time, plus the invalidation machinery to keep them safe.
    //
    // Raising the TTL past the query cost is not the fix: it would mean answering with screen
    // state up to three seconds old, which is worse than the ~0s it saves. A cache only becomes
    // worth having once a query is fast enough for two of them to land close together.
    //
    // The cost is not `waitForIdle` (dropping it 2000ms -> 200ms changed nothing) and not purely
    // per-node IPC either: `uiautomator dump` of the same 51-node tree — one shot, whole
    // hierarchy — still takes ~1.9s, so most of it is the platform's accessibility traversal on
    // this emulator. Worth re-measuring on physical hardware before treating that as a floor.

    /**
     * By default the companion's [android.app.UiAutomation] only reports the root of its own
     * instrumentation-target window. Inspecting any *other* foreground app — i.e. a real app
     * under test, whose package differs from the companion's — then comes back empty, because
     * [android.app.UiAutomation.getRootInActiveWindow] returns null for it and the multi-window
     * enumeration path is gated behind [AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS].
     *
     * The e2e suite never hit this: it drives `com.amoo.companion`'s own fixture Activity, which
     * shares the instrumentation target package, so the single-window path was always enough.
     */
    private fun enableInteractiveWindowRetrieval() {
        runCatching {
            val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            val info = automation.serviceInfo ?: return
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            automation.serviceInfo = info
        }.onFailure { Log.w(LOG_TAG, "Could not enable interactive-window retrieval", it) }
    }

    fun <T> withAppAccessibilityRoot(appId: String, operation: (AccessibilityNodeInfo) -> T): T {
        return hierarchyCapture.read { captureAppAccessibilityRoot(appId, operation) }
    }

    private fun <T> captureAppAccessibilityRoot(appId: String, operation: (AccessibilityNodeInfo) -> T): T {
        device
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
        val windows = automation.windows.orEmpty()
        val roots = windows.mapNotNull { it.root }
        try {
            val root = roots.firstOrNull { it.packageName?.toString() == appId }
                ?: error("Target app accessibility root unavailable; IME/system windows are excluded")
            return operation(root)
        } finally {
            roots.forEach { it.recycleQuietly() }
            windows.forEach { runCatching { it.recycle() } }
        }
    }

    // -- Touch --

    /**
     * A single finger tap: DOWN and UP injected back to back, as Espresso's single tap does.
     *
     * `UiDevice.click` sleeps a fixed 100ms between DOWN and UP (`InteractionController.clickNoSync`
     * in UiAutomator 2.4.0), which was about 70% of the device-side cost of every tap. Views and
     * Compose `clickable` both treat a DOWN/UP pair as a click regardless of the gap; only a
     * long-press detector needs a hold, and [longPress] keeps its own.
     */
    fun tap(x: Int, y: Int): Boolean {
        if (x < 0 || y < 0 || x >= device.displayWidth || y >= device.displayHeight) {
            Log.w(LOG_TAG, "Cannot tap ($x, $y): outside the display")
            return false
        }
        val downTime = SystemClock.uptimeMillis()
        if (!injectFingerEvent(MotionEvent.ACTION_DOWN, downTime, downTime, x.toFloat(), y.toFloat())) {
            return false
        }
        return injectFingerEvent(MotionEvent.ACTION_UP, downTime, SystemClock.uptimeMillis(), x.toFloat(), y.toFloat())
    }

    /**
     * One touchscreen event with a finger tool type and full pressure, matching what
     * `UiDevice.click` injects under this bridge's [Configurator] settings, so apps that inspect
     * the tool type see the same input as before.
     */
    private fun injectFingerEvent(
        action: Int,
        downTime: Long,
        eventTime: Long,
        x: Float,
        y: Float,
        sync: Boolean = true
    ): Boolean {
        val properties = MotionEvent.PointerProperties().apply {
            id = 0
            toolType = MotionEvent.TOOL_TYPE_FINGER
        }
        val coords = MotionEvent.PointerCoords().apply {
            this.x = x
            this.y = y
            pressure = 1f
            size = 1f
        }
        val event = MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            1,
            arrayOf(properties),
            arrayOf(coords),
            0,
            0,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0
        )
        return try {
            instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).injectInputEvent(event, sync)
        } finally {
            event.recycle()
        }
    }

    fun longPress(x: Int, y: Int, durationMs: Int): Boolean {
        // swipe in-place simulates long press
        return device.swipe(x, y, x, y, durationMs / 5)
    }

    // -- Gestures --

    fun swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, steps: Int): Boolean {
        return device.swipe(fromX, fromY, toX, toY, steps)
    }

    /**
     * A true drag: press at the origin, hold there long enough for the target to enter a
     * drag state, travel to the destination, then release.
     *
     * UiDevice.swipe/drag can't express the origin dwell — they start moving immediately,
     * which reads as a fling rather than a drag. So this injects the MotionEvent stream
     * directly, which is the only way to control the hold.
     */
    fun drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int, holdMs: Int): Boolean =
        injectPath(
            from = fromX.toFloat() to fromY.toFloat(),
            to = toX.toFloat() to toY.toFloat(),
            durationMs = durationMs,
            holdMs = holdMs.toLong(),
            settleMs = DROP_SETTLE_MS,
            eased = false
        )

    /**
     * Presses at [from], holds for [holdMs], moves to [to] over [durationMs] in real time, rests
     * for [settleMs] and lifts.
     *
     * Moves are injected without waiting for the app to consume each one. A synchronous move
     * returns only after the app's next frame, so on a busy emulator every 10 ms step cost a
     * frame (about 0.4 s) and a one-second drag overran the RPC deadline. The press and the
     * release stay synchronous, so the gesture has finished when this returns. [eased] slows the
     * finger into the destination, so the release carries no fling velocity.
     */
    private fun injectPath(
        from: Pair<Float, Float>,
        to: Pair<Float, Float>,
        durationMs: Int,
        holdMs: Long,
        settleMs: Long,
        eased: Boolean
    ): Boolean {
        val downTime = SystemClock.uptimeMillis()
        if (!injectFingerEvent(MotionEvent.ACTION_DOWN, downTime, downTime, from.first, from.second)) {
            return false
        }
        // The view's own long-press timer runs from the DOWN, so the dwell needs no events.
        if (holdMs > 0) {
            SystemClock.sleep(holdMs)
        }
        val steps = (durationMs / MOVE_INTERVAL_MS).coerceAtLeast(1)
        for (step in 1..steps) {
            val time = step.toFloat() / steps
            val progress = if (eased) easedOut(time) else time
            val x = from.first + (to.first - from.first) * progress
            val y = from.second + (to.second - from.second) * progress
            if (!injectFingerEvent(MotionEvent.ACTION_MOVE, downTime, SystemClock.uptimeMillis(), x, y, sync = false)) {
                return false
            }
            SystemClock.sleep(MOVE_INTERVAL_MS.toLong())
        }
        SystemClock.sleep(settleMs)
        return injectFingerEvent(MotionEvent.ACTION_UP, downTime, SystemClock.uptimeMillis(), to.first, to.second)
    }

    private fun easedOut(time: Float): Float {
        val remaining = 1f - time
        return 1f - remaining * remaining * remaining
    }

    /**
     * Spreads (`scale` > 1, zoom in) or pinches (`scale` < 1, zoom out) two fingers around the
     * centre, inside [bounds] (the pinched element's frame) when given, else inside the screen.
     * Returns a failure message, or null once the gesture was delivered.
     */
    fun pinch(centerX: Float, centerY: Float, scale: Float, velocity: Float, bounds: RectF?): String? {
        val density = instrumentation.targetContext.resources.displayMetrics.density
        val screen = RectF(0f, 0f, device.displayWidth.toFloat(), device.displayHeight.toFloat())
        // Fingers outside the element land on its neighbours, so its pinch detector never fires.
        val fitted = bounds?.let { RectF(it) }?.takeIf { it.intersect(screen) } ?: screen
        val gesture = PinchGesture.fit(centerX, centerY, scale, velocity, fitted, density) ?: return "pinch scale must be a positive number other than 1 (above 1 zooms in, below 1 zooms out); got $scale"
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        // Moves go in without waiting for a frame each, as in [injectPath]; the fingers landing and
        // lifting stay synchronous.
        val delivered = PinchInjector { event ->
            automation.injectInputEvent(event, event.actionMasked != MotionEvent.ACTION_MOVE)
        }.perform(gesture)
        return if (delivered) null else "pinch input injection was rejected"
    }

    /**
     * Drags the content [distance] pixels so that [direction] comes into view, from a path
     * centred on the screen, and stops it there.
     *
     * `UiDevice.swipe` crossed the distance in 100 ms and lifted while still moving, so the list
     * travelled about half the requested distance. This eases the finger to a stop, rests and
     * lifts, and adds the touch slop a list consumes before it starts to move.
     */
    fun scroll(direction: Direction, distance: Int): Boolean {
        val (width, height) = device.displayWidth to device.displayHeight
        val (unitX, unitY) = when (direction) {
            Direction.UP -> 0 to 1
            Direction.DOWN -> 0 to -1
            Direction.LEFT -> 1 to 0
            Direction.RIGHT -> -1 to 0
        }
        val extent = if (unitX != 0) width else height
        val slop = ViewConfiguration.get(instrumentation.targetContext).scaledTouchSlop
        val travel = minOf(distance.coerceAtLeast(1) + slop, (extent * SCROLL_MAX_EXTENT).roundToInt()).toFloat()
        val (centreX, centreY) = width / 2f to height / 2f
        return injectPath(
            from = centreX - unitX * travel / 2 to centreY - unitY * travel / 2,
            to = centreX + unitX * travel / 2 to centreY + unitY * travel / 2,
            durationMs = SCROLL_DURATION_MS,
            holdMs = 0,
            settleMs = SCROLL_SETTLE_MS,
            eased = true
        )
    }

    fun swipeInDirection(
        direction: Direction,
        distance: Int,
        durationMs: Int,
        resourceId: String?,
        text: String?
    ): Boolean {
        val steps = (durationMs / 5).coerceAtLeast(1)
        val (w, h) = device.displayWidth to device.displayHeight

        if (resourceId != null || text != null) {
            val selector = androidx.test.uiautomator.UiSelector().let { s ->
                var result = s
                if (resourceId != null) result = result.resourceId(resourceId)
                if (text != null) result = result.text(text)
                result
            }
            val obj = device.findObject(selector)
            if (obj != null && obj.exists()) {
                val bounds = obj.bounds
                val cx = bounds.centerX()
                val cy = bounds.centerY()
                val (dx, dy) = directionDelta(direction, distance)
                return device.swipe(cx, cy, cx + dx, cy + dy, steps)
            }
        }

        val cx = w / 2
        val cy = h / 2
        val (dx, dy) = directionDelta(direction, distance)
        return device.swipe(cx, cy, cx + dx, cy + dy, steps)
    }

    private fun directionDelta(direction: Direction, distance: Int): Pair<Int, Int> = when (direction) {
        Direction.UP -> 0 to -distance
        Direction.DOWN -> 0 to distance
        Direction.LEFT -> -distance to 0
        Direction.RIGHT -> distance to 0
    }

    // -- Text --

    fun typeText(text: String) {
        device.waitForIdle(2000)
        val focused = device.findObject(By.focused(true))
            ?: device.findObject(By.clazz("android.widget.EditText"))
        focused?.text = text
    }

    fun clearText() {
        device.waitForIdle(2000)
        val focused = device.findObject(By.focused(true))
            ?: device.findObject(By.clazz("android.widget.EditText"))
        focused?.clear()
    }

    fun setText(resourceId: String?, label: String?, containsText: String?, value: String): Boolean {
        val started = SystemClock.uptimeMillis()
        val candidates = textTargets(resourceId, label, containsText)
        val found = SystemClock.uptimeMillis()
        val match = candidates.singleOrNull()
        if (match == null) {
            Log.w(LOG_TAG, "set_text no_single_target candidates=${candidates.size}")
            return false
        }
        val target = match.handle
        val secure = match.secure
        val before = match.text
        target.click()
        val clicked = SystemClock.uptimeMillis()
        target.text = value
        val written = SystemClock.uptimeMillis()
        // A Compose field shows the new value on its next recomposition, so the first read can
        // still return the old text; give it a moment before calling the entry rejected.
        val deadline = SystemClock.uptimeMillis() + SET_TEXT_SETTLE_MS
        var after = runCatching { target.text.orEmpty() }.getOrDefault("")
        while (!setTextAccepted(value, before, after, secure) && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(50)
            after = runCatching { target.text.orEmpty() }.getOrDefault("")
        }
        val accepted = setTextAccepted(value, before, after, secure)
        val verified = SystemClock.uptimeMillis()
        // Lengths and timings only: the value may be a secret.
        Log.i(
            LOG_TAG,
            "set_text accepted=$accepted secure=$secure class=${runCatching { target.className }.getOrNull()} " +
                "valueLength=${value.length} beforeLength=${before.length} afterLength=${after.length} " +
                "find_ms=${found - started} click_ms=${clicked - found} write_ms=${written - clicked} " +
                "verify_ms=${verified - written}"
        )
        return accepted
    }

    /** Password fields report masks, but their content still has to change. */
    private fun setTextAccepted(value: String, before: String, after: String, secure: Boolean): Boolean =
        after == value || (secure && value.isNotEmpty() && after.isNotEmpty() && after != before)

    // -- Navigation --

    fun pressBack(): Boolean {
        device.waitForIdle(WAIT_FOR_IDLE_MS)
        // `UiDevice.pressBack()` only returns true if it observes a TYPE_WINDOW_CONTENT_CHANGED
        // event within ~1s of the key press. A Compose destination change frequently emits only
        // TYPE_WINDOW_STATE_CHANGED, or the new content settles after the transition animation —
        // so the navigation happens while the call reports "back navigation failed".
        // `performGlobalAction` dispatches the same Back and reports only whether the action was
        // accepted, which is the signal the caller actually wants. Key injection is the fallback.
        val dispatched = runCatching {
            instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        }.getOrDefault(false)
        if (dispatched) {
            device.waitForIdle(WAIT_FOR_IDLE_MS)
            return true
        }
        return device.pressKeyCode(KeyEvent.KEYCODE_BACK)
    }

    fun pressHome(): Boolean = device.pressHome()

    // -- Accessibility --

    /**
     * Elements matching the selector, or every element when no selector is given.
     *
     * Unlabeled elements are included by default, so an icon-only control with no content
     * description is still reachable by its frame. [labeledOnly] drops them, for callers that
     * only want elements they can name — the accessibility reports are not among them, since an
     * element with no id and no label is the finding they produce.
     * A selector makes it moot: an element with no id and no label matches none of them.
     */
    fun findElements(
        resourceId: String?,
        text: String?,
        containsText: String?,
        appId: String? = null,
        labeledOnly: Boolean = false
    ): List<ElementSnapshot> {
        return withCurrentElements(appId) { elements ->
            matchingElements(scopedElements(elements, appId), resourceId, text, containsText)
                .map { it.toSnapshot() }
                .filter { !labeledOnly || it.id.isNotBlank() || it.label.isNotBlank() }
        }
    }

    fun getAllElements(appId: String? = null): List<ElementSnapshot> {
        return withCurrentElements(appId) { elements ->
            scopedElements(elements, appId).map { it.toSnapshot() }
        }
    }

    /**
     * The element a tap should actually land on, which is not always the element that matched.
     *
     * Classic Android Views put text, content description, resource id and clickability on one
     * node, so "first match" was always the right target. Jetpack Compose does not: a Button
     * becomes several sibling semantics nodes — one clickable node carrying the testTag, and
     * separate non-clickable nodes carrying the text and the content description. Matching on a
     * label or on text therefore resolves a node that cannot be clicked, and tapping its centre
     * only works by accident, when its bounds happen to sit inside the real click target.
     *
     * So: prefer a match that is itself clickable, then the nearest clickable ancestor of a match,
     * and only fall back to the raw match when neither exists (which keeps behaviour unchanged for
     * genuinely non-interactive elements).
     */
    fun findTapTarget(
        resourceId: String?,
        text: String?,
        containsText: String?,
        appId: String? = null
    ): ElementSnapshot? {
        return withCurrentElements(appId) { elements ->
            val matches = matchingElements(scopedElements(elements, appId), resourceId, text, containsText)
            if (matches.size != 1) return@withCurrentElements null
            matches.firstOrNull { it.isClickable }?.let { return@withCurrentElements it.toSnapshot() }
            matches.firstNotNullOfOrNull { it.clickableAncestor }
                ?.let { return@withCurrentElements it.toSnapshot() }
            matches.firstOrNull()?.toSnapshot()
        }
    }

    /**
     * Elements from [appId]'s process, or every process when [appId] is null/blank.
     *
     * Unlike iOS's XCUITest, which isolates each app's accessibility tree behind
     * XCUIApplication(bundleIdentifier:), UIAutomator2's root query already returns every
     * visible window system-wide in one flat list — an app's own UI and system UI (permission
     * dialogs, the notification shade) mixed together. So scoping to [appId] is a filter, not a
     * separate lookup. An empty app result stays empty; callers explicitly request system scope.
     */
    private fun scopedElements(all: List<NodeRecord>, appId: String?): List<NodeRecord> {
        if (appId.isNullOrBlank()) return all
        val scoped = all.filter { it.packageName == appId }
        return scoped
    }

    fun getInteractableElements(): List<ElementSnapshot> {
        return withCurrentElements { elements ->
            elements
                .filter { it.isClickable || it.isLongClickable || it.type.contains("EditText") }
                .map { it.toSnapshot() }
        }
    }

    fun findByDescription(description: String): List<ElementSnapshot> {
        val query = description.lowercase()
        return getAllElements().filter { snapshot ->
            snapshot.id.lowercase().contains(query) || snapshot.label.lowercase().contains(query)
        }
    }

    /** App explicitly bound via [setTargetPackageName], for query/gesture scoping. Unbound by default. */
    @Volatile
    private var boundTargetPackageName: String? = null

    fun currentPackageName(): String {
        return device.currentPackageName ?: targetPackageName
    }

    fun targetPackageNameBinding(): String? = boundTargetPackageName

    fun setTargetPackageName(bundleId: String?) {
        boundTargetPackageName = bundleId
    }

    fun screenWidth(): Int = device.displayWidth

    fun screenHeight(): Int = device.displayHeight

    fun isKeyboardVisible(): Boolean {
        // Heuristic: check if IME is shown via shell command
        val output = device.executeShellCommand("dumpsys input_method | grep mInputShown")
        return output.contains("mInputShown=true")
    }

    // -- Screenshot --

    fun takeScreenshot(): ByteArray {
        val file = java.io.File.createTempFile("screenshot", ".png")
        device.takeScreenshot(file)
        val bytes = file.readBytes()
        file.delete()
        return bytes
    }

    /**
     * One capture, scaled and encoded in memory before it crosses gRPC.
     *
     * [fraction] is of native pixels per side; [pointResolution] asks for one pixel per
     * density-independent pixel (fraction = 1 / density), which is what keeps a capture of a
     * 420 dpi screen at about a seventh of its pixels. Falls back to the file-based capture when
     * UiAutomation returns no bitmap.
     */
    fun captureScreen(fraction: Double, pointResolution: Boolean, jpegQuality: Double?): CapturedScreen {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val density = instrumentation.targetContext.resources.displayMetrics.density.toDouble()
        val bitmap = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).takeScreenshot()
            ?: return CapturedScreen(takeScreenshot(), "png", 0.0, screenWidth(), screenHeight(), density)
        val target = when {
            pointResolution -> 1.0 / density.coerceAtLeast(1.0)
            fraction > 0.0 && fraction < 1.0 -> fraction
            else -> 1.0
        }
        val applied = target.coerceIn(0.05, 1.0)
        val output = if (applied < 1.0) {
            downscale(
                bitmap,
                (bitmap.width * applied).roundToInt().coerceAtLeast(1),
                (bitmap.height * applied).roundToInt().coerceAtLeast(1)
            )
        } else {
            bitmap
        }
        val stream = ByteArrayOutputStream()
        val jpeg = jpegQuality != null
        output.compress(
            if (jpeg) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG,
            ((jpegQuality ?: 1.0) * 100).roundToInt().coerceIn(1, 100),
            stream
        )
        val width = bitmap.width
        val height = bitmap.height
        if (output !== bitmap) output.recycle()
        bitmap.recycle()
        return CapturedScreen(
            stream.toByteArray(), if (jpeg) "jpeg" else "png", if (applied < 1.0) applied else 0.0,
            width, height, density
        )
    }

    /**
     * Scales [source] to [width] x [height] in steps of at most half.
     *
     * A bilinear filter reads a 2x2 neighbourhood, so one pass below half size skips source pixels
     * and thin strokes (1dp rules, small text) can disappear. Halving first averages every source
     * pixel into the result. Intermediate bitmaps are recycled; [source] is left to the caller.
     */
    private fun downscale(source: Bitmap, width: Int, height: Int): Bitmap {
        var current = source
        while (current.width / 2 >= width && current.height / 2 >= height) {
            val half = Bitmap.createScaledBitmap(current, current.width / 2, current.height / 2, true)
            if (current !== source) current.recycle()
            current = half
        }
        if (current.width == width && current.height == height) return current
        val result = Bitmap.createScaledBitmap(current, width, height, true)
        if (current !== source) current.recycle()
        return result
    }

    private fun NodeRecord.toSnapshot(): ElementSnapshot = ElementSnapshot(
        id = id,
        label = label,
        value = value,
        type = type,
        frame = FrameRect(bounds.left, bounds.top, bounds.width(), bounds.height()),
        isEnabled = isEnabled,
        isVisible = isVisible,
        isSecureTextEntry = isSecureTextEntry,
        placeholder = placeholder,
        visibleFrame = visibleBounds(),
        isSelected = isSelected,
        reference = reference,
        parentReference = parentReference,
        hierarchyPath = hierarchyPath,
        attributes = if (childrenTruncated) {
            attributes + ("childrenTruncated" to "webview subtree time budget; use webview_dom for its content")
        } else {
            attributes
        }
    )

    private fun NodeRecord.visibleBounds(): FrameRect {
        val visible = Rect(bounds)
        val viewport = scrollBounds ?: Rect(0, 0, device.displayWidth, device.displayHeight)
        if (!isVisible || !visible.intersect(viewport)) visible.setEmpty()
        return FrameRect(visible.left, visible.top, visible.width(), visible.height())
    }

    private fun matchingElements(
        elements: List<NodeRecord>,
        resourceId: String?,
        text: String?,
        containsText: String?
    ): List<NodeRecord> = preferResourceID(
        elements.filter { matches(it, resourceId, text, containsText) }, resourceId, NodeRecord::resourceName
    )

    private inline fun <T> preferResourceID(
        matches: List<T>,
        resourceId: String?,
        resourceName: (T) -> String
    ): List<T> {
        if (resourceId.isNullOrBlank() || matches.size <= 1) return matches
        return matches.filter {
            val name = resourceName(it)
            resourceId == name || resourceId == unqualifiedResourceID(name)
        }.ifEmpty { matches }
    }

    private fun matches(
        element: NodeRecord,
        resourceId: String?,
        text: String?,
        containsText: String?
    ): Boolean {
        val elementText = element.value
        val contentDescription = element.contentDescription
        val resourceName = element.resourceName
        val normalizedID = element.id

        if (resourceId != null && resourceId != normalizedID &&
            resourceId != contentDescription && resourceId != resourceName
        ) {
            return false
        }

        if (text != null && (element.labelMergedUp || text != elementText && text != contentDescription &&
                text != element.label && text !in element.mergedLabels)
        ) {
            return false
        }

        if (containsText != null && (element.labelMergedUp || !elementText.contains(containsText) &&
                !contentDescription.contains(containsText) && !element.label.contains(containsText))
        ) {
            return false
        }

        // No selector means "everything on screen", which is how an icon-only control with neither
        // id nor label is found at all — `find_elements` with no arguments is the documented way in
        // (see plugins/amoo/skills/driving-amoo). This used to return false here, so that call answered 0
        // elements on Android while iOS listed the whole tree.
        return true
    }

    private fun normalizedElementID(resourceName: String, contentDescription: String): String =
        unqualifiedResourceID(resourceName).ifBlank { contentDescription }

    private fun unqualifiedResourceID(resourceName: String): String =
        resourceName.substringAfterLast(':').substringAfterLast('/')

    /**
     * Queries operate on one complete immutable capture. Tree changes are retried during capture,
     * before filtering, so partial results cannot make a selector appear absent.
     */
    private inline fun <T> withCurrentElements(appId: String? = null, operation: (List<NodeRecord>) -> T): T {
        return operation(currentElements(appId))
    }

    /**
     * Every field a query needs, read once from one [AccessibilityNodeInfo].
     *
     * This exists for speed, and the margin is large. A [UiObject2] is a cursor, not a value: each
     * accessor (`text`, `contentDescription`, `resourceName`, `className`, `visibleBounds`,
     * `isEnabled`) refreshes the node over IPC, so building one snapshot cost roughly six round
     * trips and `matches` + `toSnapshot` together cost about nine. Profiled on a booted emulator
     * against a sample app, a 77-node screen spent 13ms walking the tree and ~2.6s on those reads —
     * about 5.7ms per property, ~460 round trips per query.
     *
     * `AccessibilityNodeInfo` already carries all of it locally once fetched, so the same screen
     * needs one fetch per node instead of nine.
     */
    private class NodeRecord(
        val reference: String,
        val parentReference: String,
        val hierarchyPath: String,
        val isSelected: Boolean,
        val attributes: Map<String, String>,
        val scrollBounds: Rect?,
        val scrollReference: String,
        val id: String,
        /** `var` so [mergeOwnedLabels] can give a label-less clickable node its descendants' text. */
        var label: String,
        val value: String,
        val type: String,
        /** Kept alongside [label]: an element can carry both text and a content description, and
         *  a selector may name either. Deriving one from the other loses that. */
        val contentDescription: String,
        val resourceName: String,
        val packageName: String,
        val bounds: Rect,
        val isEnabled: Boolean,
        val isVisible: Boolean,
        val isClickable: Boolean,
        val isLongClickable: Boolean,
        val isSecureTextEntry: Boolean,
        val placeholder: String?,
        /**
         * Nearest clickable ancestor, resolved while walking rather than by climbing `parent`
         * afterwards — a parent walk is another IPC per step, and the walk already knows the
         * answer. Compose needs this: a Button becomes sibling semantics nodes where the one
         * carrying the text is not the one that is clickable.
         */
        val clickableAncestor: NodeRecord? = null
    ) {
        /** The descendant labels [label] was merged from; a label selector may name any one of them. */
        var mergedLabels: List<String> = emptyList()

        /** Set on a descendant whose label now speaks for its clickable owner, so a label selector
         *  resolves to the one control rather than to both it and its icon. */
        var labelMergedUp = false

        /** Set on a WebView whose subtree the capture stopped walking at its time budget. */
        var childrenTruncated = false
    }

    private fun currentElements(appId: String? = null): List<NodeRecord> {
        return hierarchyCapture.read {
            try {
                captureCurrentElements(appId)
            } catch (_: StaleObjectException) {
                throw HierarchyChangedException()
            }
        }
    }

    private fun captureCurrentElements(appId: String?): List<NodeRecord> {
        val started = SystemClock.elapsedRealtime()
        Log.i(LOG_TAG, "hierarchy_start scope=${if (appId == null) "all" else "app"}")
        device
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        // Drop the process-wide `AccessibilityCache` before every read. Without this, after a
        // navigation `automation.windows` keeps returning a stale `AccessibilityWindowInfo` whose
        // `.root` is the *previous* screen's tree — nothing here invalidates it, so `find_elements`
        // / `describe_screen` stay pinned to the old screen while `take_screenshot` (a different
        // path) correctly shows the new one. Re-reading from the service is the per-query cost
        // this file already accepts and documents at length above. `clearCache()` is API 34+ and
        // public; there is no earlier public entry point, but the supported devices are 34+.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            runCatching { automation.clearCache() }
        }
        // `AccessibilityWindowInfo` and the `AccessibilityNodeInfo` roots/children obtained below
        // both need `recycle()`: minSdk is 26, and recycle() only became a no-op at API 33 (it is
        // real cleanup below that). Un-recycled nodes stay in the client-side node cache
        // (AccessibilityInteractionClient) for the life of the instrumentation process, so a
        // companion left running through many sessions on 26-32 would leak one node per element
        // per query, indefinitely. Recycling here is free where it doesn't matter (33+) and
        // correct where it does — there is no on-device way to demonstrate the leak itself on
        // this project's API 35 test emulator, but the requirement is documented, not conditional.
        // The app's own windows first, then system ones: the status bar sits on top in z-order, and
        // walking it first filled a result page with SystemUI nodes before any app control.
        val windows = runCatching { automation.windows }.getOrNull().orEmpty()
            .sortedBy { if (it.type == AccessibilityWindowInfo.TYPE_APPLICATION) 0 else 1 }
        val roots = windows.mapNotNull { it.root }
            .ifEmpty { listOfNotNull(automation.rootInActiveWindow) }

        if (roots.isEmpty()) {
            Log.w(
                LOG_TAG,
                "currentElements found no window roots. " +
                    "serviceInfoFlags=${automation.serviceInfo?.flags}"
            )
            for (window in windows) runCatching { window.recycle() }
            throw HierarchyChangedException()
        }

        val out = ArrayList<NodeRecord>()
        val deadline = SystemClock.uptimeMillis() + 8_000
        try {
            val capture = java.util.UUID.randomUUID().toString()
            for ((index, root) in roots.withIndex()) {
                if (appId != null && root.packageName?.toString() != appId) continue
                collectRecords(root, nearestClickable = null, parent = null,
                    path = "window[$index]", capture = capture, deadline = deadline,
                    depth = 0, into = out)
            }
        } finally {
            for (root in roots) root.recycleQuietly()
            for (window in windows) runCatching { window.recycle() }
        }
        mergeOwnedLabels(out)
        Log.i(LOG_TAG, "hierarchy_complete roots=${roots.size} nodes=${out.size} elapsed_ms=${SystemClock.elapsedRealtime() - started}")
        return out
    }

    /**
     * Gives a clickable node with no text or description of its own the labels of the descendants
     * it owns, the way TalkBack and Compose's merged semantics announce it.
     *
     * The standard Compose pattern, `IconButton(Modifier.testTag(id)) { Icon(contentDescription = "Play") }`,
     * puts the id on the clickable node and the description on its child. The tagged node was reported
     * with an empty label, so a selector naming both id and label never matched on Android while the
     * same selector worked on iOS, where XCUITest merges them. A descendant inside a nested clickable
     * belongs to that one instead.
     */
    private fun mergeOwnedLabels(records: List<NodeRecord>) {
        val owned = records
            .filter { it.label.isNotBlank() && it.clickableAncestor != null && !it.isClickable }
            .groupBy { it.clickableAncestor?.reference.orEmpty() }
        for (record in records) {
            if (!record.isClickable || record.label.isNotBlank()) continue
            val children = owned[record.reference].orEmpty()
            val parts = children.map { it.label }.distinct()
            if (parts.isEmpty()) continue
            record.label = parts.joinToString(", ")
            record.mergedLabels = parts
            for (child in children) child.labelMergedUp = true
        }
    }

    private fun collectRecords(
        node: AccessibilityNodeInfo,
        nearestClickable: NodeRecord?,
        parent: NodeRecord?,
        path: String,
        capture: String,
        deadline: Long,
        depth: Int,
        into: MutableList<NodeRecord>,
        webViewDeadline: Long? = null
    ) {
        check(!io.grpc.Context.current().isCancelled) { "Hierarchy capture cancelled before completion" }
        // Each limit is named, with how far the walk got: only the time limit is worth retrying
        // (an animating screen slows every node read), while depth and size are properties of the tree.
        check(depth <= MAX_TREE_DEPTH) {
            "Hierarchy capture incomplete: depth limit $MAX_TREE_DEPTH exceeded after ${into.size} nodes"
        }
        check(into.size < 10_000) { "Hierarchy capture incomplete: node limit 10000 exceeded" }
        check(SystemClock.uptimeMillis() < deadline) {
            "Hierarchy capture incomplete: time limit exceeded after ${into.size} nodes"
        }
        val record = node.toRecord(nearestClickable, parent, path, capture)
        into.add(record)
        val ancestorForChildren = if (record.isClickable) record else nearestClickable
        // A playing WebView rebuilds its accessibility tree every frame, and each child read waits on
        // it: one capture stalled for over 12 seconds and every later query queued behind it. Its
        // subtree gets a budget of its own; past it the walk stops descending and marks the WebView,
        // whose content `webview_dom` / `webview_eval` read directly.
        val subtreeDeadline = webViewDeadline ?: if (record.type.contains("WebView")) {
            SystemClock.uptimeMillis() + WEBVIEW_SUBTREE_BUDGET_MS
        } else {
            null
        }
        for (index in 0 until node.childCount) {
            if (subtreeDeadline != null && SystemClock.uptimeMillis() >= subtreeDeadline) {
                record.childrenTruncated = true
                Log.w(LOG_TAG, "hierarchy_webview_truncated path=$path nodes=${into.size}")
                break
            }
            val child = node.getChild(index) ?: throw HierarchyChangedException()
            try {
                collectRecords(
                    child, ancestorForChildren, record, "$path/$index", capture, deadline, depth + 1, into,
                    subtreeDeadline
                )
            } finally {
                child.recycleQuietly()
            }
        }
    }

    /** [AccessibilityNodeInfo.recycle] on an object obtained via `runCatching`, so a node that
     *  went stale mid-walk (the app changed under us) doesn't throw on the way out. */
    private fun AccessibilityNodeInfo.recycleQuietly() {
        runCatching { recycle() }
    }

    private fun AccessibilityNodeInfo.toRecord(
        nearestClickable: NodeRecord?, parent: NodeRecord?, path: String, capture: String
    ): NodeRecord {
        val rect = Rect().also { getBoundsInScreen(it) }
        val contentDescription = contentDescription?.toString().orEmpty()
        val resourceName = viewIdResourceName.orEmpty()
        val textValue = text?.toString().orEmpty()
        val viewport = Rect(0, 0, device.displayWidth, device.displayHeight)
        val scrollParent = parent?.attributes?.get("scrollable") == "true"
        val scrollBounds = if (scrollParent) parent?.bounds else parent?.scrollBounds
        val scrollReference = if (scrollParent) parent?.reference.orEmpty() else parent?.scrollReference.orEmpty()
        val clippingBounds = scrollBounds ?: viewport
        val touchesEdge = rect.left <= clippingBounds.left || rect.top <= clippingBounds.top ||
            rect.right >= clippingBounds.right || rect.bottom >= clippingBounds.bottom
        val properties = mutableMapOf(
            "provider" to "AccessibilityNodeInfo",
            "coordinateUnit" to "pixels",
            "boundsKind" to "providerReported",
            "fullBoundsAvailability" to "unavailable: exporter cannot establish unclipped layout bounds",
            "clipping" to if (touchesEdge) "possible" else "unknown",
            "rawResourceId" to resourceName,
            "showingHintText" to isShowingHintText.toString(),
            "rawText" to if (isPassword) "[redacted]" else textValue,
            "contentDescription" to contentDescription,
            "className" to className?.toString().orEmpty(),
            "selected" to isSelected.toString(),
            "checkable" to isCheckable.toString(),
            "checked" to isChecked.toString(),
            "clickable" to isClickable.toString(),
            "focusable" to isFocusable.toString(),
            "scrollable" to isScrollable.toString(),
            "computedNameAvailability" to "unavailable: screen-reader name computation not observed",
            "actions" to actionList.joinToString(",") { it.id.toString() },
            "scrollContainerReference" to scrollReference,
            "roleDescription" to extras.getCharSequence("AccessibilityNodeInfo.roleDescription")?.toString().orEmpty()
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            properties["stateDescription"] = stateDescription?.toString().orEmpty()
        } else {
            properties["stateDescriptionAvailability"] = "unsupported before API 30"
        }
        val labelingNode = labeledBy
        try {
            properties["labelAssociationAvailability"] = if (labelingNode == null) "noneReported" else "reported"
            labelingNode?.let {
                properties["labeledByResourceId"] = it.viewIdResourceName.orEmpty()
                properties["labeledByText"] = it.text?.toString().orEmpty()
                properties["labeledByContentDescription"] = it.contentDescription?.toString().orEmpty()
            }
        } finally {
            labelingNode?.recycleQuietly()
        }
        rangeInfo?.let {
            properties["rangeMin"] = it.min.toString()
            properties["rangeMax"] = it.max.toString()
            properties["rangeCurrent"] = it.current.toString()
        }
        return NodeRecord(
            reference = "$capture:$path",
            parentReference = parent?.reference.orEmpty(),
            hierarchyPath = path,
            isSelected = isSelected,
            attributes = properties,
            scrollBounds = scrollBounds,
            scrollReference = scrollReference,
            id = normalizedElementID(resourceName, contentDescription),
            label = textValue.ifBlank { contentDescription },
            value = if (isEditable && isShowingHintText) "" else textValue,
            type = className?.toString().orEmpty(),
            contentDescription = contentDescription,
            resourceName = resourceName,
            packageName = packageName?.toString().orEmpty(),
            bounds = rect,
            isEnabled = isEnabled,
            isVisible = isVisibleToUser,
            isClickable = isClickable,
            isLongClickable = isLongClickable,
            isSecureTextEntry = isPassword,
            placeholder = hintText?.toString()?.ifBlank { null },
            clickableAncestor = nearestClickable
        )
    }

    private data class TextTarget(
        val handle: UiObject2,
        val text: String,
        val secure: Boolean
    )

    private fun textTargets(resourceId: String?, label: String?, containsText: String?): List<TextTarget> {
        if (resourceId.isNullOrBlank()) {
            return uiObjectTree().mapNotNull { textTarget(it, resourceId, label, containsText) }
        }
        val resourcePattern = Pattern.compile("(?:.*[:/])?${Pattern.quote(resourceId)}")
        val direct = device.findObjects(By.res(resourcePattern))
            .mapNotNull { textTarget(it, resourceId, label, containsText) }
        return direct.ifEmpty {
            device.findObjects(By.desc(resourceId)).mapNotNull { textTarget(it, resourceId, label, containsText) }
        }
    }

    /** Reads the selector fields and password state from one refresh of the writable node. */
    private fun textTarget(
        element: UiObject2,
        resourceId: String?,
        text: String?,
        containsText: String?
    ): TextTarget? {
        val node = runCatching { element.accessibilityNodeInfo }.getOrNull() ?: return null
        val elementText = node.text?.toString().orEmpty()
        val contentDescription = node.contentDescription?.toString().orEmpty()
        val resourceName = node.viewIdResourceName.orEmpty()
        val normalizedID = normalizedElementID(resourceName, contentDescription)

        if (resourceId != null && resourceId != normalizedID &&
            resourceId != contentDescription && resourceId != resourceName
        ) {
            return null
        }
        if (text != null && text != elementText && text != contentDescription) {
            return null
        }
        if (containsText != null && !elementText.contains(containsText) &&
            !contentDescription.contains(containsText)
        ) {
            return null
        }
        return TextTarget(element, elementText, node.isPassword)
    }

    private fun uiObjectTree(): List<UiObject2> {
        device.waitForIdle(WAIT_FOR_IDLE_MS)

        val roots = device.findObjects(By.depth(0)).ifEmpty {
            // Some emulator / API-level combinations return nothing from a depth-only selector
            // even with interactive-window retrieval enabled. Matching "any package" forces
            // ByMatcher to walk every window root it can reach.
            device.findObjects(By.pkg(ANY_PACKAGE))
        }

        if (roots.isEmpty()) {
            val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
            Log.w(
                LOG_TAG,
                "currentElements found no window roots. " +
                    "serviceInfoFlags=${automation.serviceInfo?.flags} " +
                    "windows=${runCatching { automation.windows.size }.getOrNull()} " +
                    "activeRoot=${runCatching { automation.rootInActiveWindow != null }.getOrNull()} " +
                    "currentPackage=${device.currentPackageName}"
            )
        }

        return roots
            .flatMap { root -> sequenceOf(root) + root.children.asSequence().flatMap { collectDescendants(it) } }
            .toList()
    }

    private fun collectDescendants(node: UiObject2): Sequence<UiObject2> {
        return sequenceOf(node) + node.children.asSequence().flatMap { child -> collectDescendants(child) }
    }
}

/** A screenshot and the native pixel size of the same frame. */
data class CapturedScreen(
    val data: ByteArray,
    val format: String,
    /** Fraction of native pixels per side applied; 0 when the image is native. */
    val appliedScale: Double,
    val widthPixels: Int,
    val heightPixels: Int,
    /** Native pixels per density-independent pixel. */
    val density: Double
)
