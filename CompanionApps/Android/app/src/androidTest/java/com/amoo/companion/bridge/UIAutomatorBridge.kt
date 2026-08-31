package com.amoo.companion.bridge

import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Rect
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import java.util.regex.Pattern

/**
 * Single point of contact with Android's UIAutomator2 framework.
 * If UIAutomator APIs change, only this file changes.
 */
class UIAutomatorBridge {
    private companion object {
        /** Gap between injected ACTION_MOVE events during a drag, in milliseconds. */
        const val MOVE_INTERVAL_MS = 10

        /** Dwell at the destination before lifting, so drop targets see the drag finish. */
        const val DROP_SETTLE_MS = 200L

        /**
         * How far up the tree to look for a clickable ancestor. Compose nests a matched semantics
         * node only a few levels under its clickable owner; a larger bound would start returning
         * whole screens as tap targets.
         */
        const val MAX_ANCESTOR_WALK = 5

        /** Quiescence wait before reading the hierarchy, so a mid-transition frame is not captured. */
        const val WAIT_FOR_IDLE_MS = 2_000L

        /**
         * Deliberately short: long enough to collapse the burst of queries an agent issues
         * about one screen state, short enough that a live UiObject2 handle cannot go stale
         * unnoticed, and short enough that a host-side polling assertion still observes a
         * change well inside its timeout.
         */
        const val ELEMENT_CACHE_TTL_MS = 150L

        const val LOG_TAG = "AmooCompanion"

        /** Matches any application package, used to force a full multi-window root walk. */
        val ANY_PACKAGE: Pattern = Pattern.compile(".+")
    }

    // Netty may deliver the first two RPCs concurrently, so initialization must be serialized too.
    private val instrumentation by lazy {
        InstrumentationRegistry.getInstrumentation()
    }
    private val device by lazy {
        UiDevice.getInstance(instrumentation).also { enableInteractiveWindowRetrieval() }
    }
    private val targetPackageName by lazy {
        instrumentation.targetContext.packageName
    }

    /**
     * The window roots and descendants from the most recent query, reused for queries that arrive
     * before anything can have changed them.
     *
     * [currentElements] is the whole cost of a query: a [UiDevice.waitForIdle] followed by a full
     * walk of every window root. Agents habitually query several times about one screen state —
     * "did it appear?", "what's on screen?", then a selector lookup — and each of those was paying
     * for both again. The iOS bridge caches [androidx.test.uiautomator.UiObject2]'s equivalent for
     * the same reason; see XCUITestBridge.cachedSnapshot for the measured numbers there.
     *
     * Unlike iOS's XCUIElementSnapshot, a [UiObject2] is a *live* handle to an accessibility node,
     * not an immutable copy: the node behind it can be recycled, after which any property read
     * throws StaleObjectException. Three things keep that safe:
     *
     * - Every mutating RPC calls [invalidateElementCache], so a cached handle never outlives an
     *   action taken through the companion.
     * - [ELEMENT_CACHE_TTL_MS] is short, bounding the window in which the app can recycle a node
     *   on its own (an async load, an animation, a timer) without us knowing.
     * - Every query goes through [withCurrentElements], which retries the full operation once when
     *   any property access finds a recycled node.
     *
     * The TTL also keeps polling assertions correct: assert_visible / assert_enabled /
     * assert_screen_changed loop host-side, so the companion cannot tell a poll from a one-shot
     * query and has nothing to bypass on. With expiry a poll sees a change at worst one TTL late;
     * without it the loop would re-read identical state until its deadline and report a timeout
     * for a change that did happen.
     */
    private var cachedElements: List<UiObject2>? = null
    private var cachedElementsAt: Long = 0L
    private var elementCacheGeneration: Long = 0L
    private val elementCacheLock = Any()

    /** Drops the cached tree. Called by every RPC that can change what is on screen. */
    private fun invalidateElementCache() {
        synchronized(elementCacheLock) {
            cachedElements = null
            elementCacheGeneration++
        }
    }

    /**
     * Invalidates on both sides of a mutation. The leading invalidation prevents the action from
     * consuming old handles; the trailing one prevents a concurrent query that overlapped the
     * gesture from publishing its mid-transition tree after the first invalidation.
     */
    private inline fun <T> mutatingOperation(block: () -> T): T {
        invalidateElementCache()
        return try {
            block()
        } finally {
            invalidateElementCache()
        }
    }

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
            val automation = instrumentation.uiAutomation
            val info = automation.serviceInfo ?: return
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo = info
        }.onFailure { Log.w(LOG_TAG, "Could not enable interactive-window retrieval", it) }
    }

    // -- Touch --

    fun tap(x: Int, y: Int): Boolean = mutatingOperation { device.click(x, y) }

    fun longPress(x: Int, y: Int, durationMs: Int): Boolean {
        return mutatingOperation {
            device.swipe(x, y, x, y, durationMs / 5) // swipe in-place simulates long press
        }
    }

    // -- Gestures --

    fun swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, steps: Int): Boolean {
        return mutatingOperation { device.swipe(fromX, fromY, toX, toY, steps) }
    }

    /**
     * A true drag: press at the origin, hold there long enough for the target to enter a
     * drag state, travel to the destination, then release.
     *
     * UiDevice.swipe/drag can't express the origin dwell — they start moving immediately,
     * which reads as a fling rather than a drag. So this injects the MotionEvent stream
     * directly, which is the only way to control the hold.
     */
    fun drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int, holdMs: Int): Boolean {
        return mutatingOperation {
            val downTime = SystemClock.uptimeMillis()

            if (!injectPointerEvent(MotionEvent.ACTION_DOWN, downTime, downTime, fromX, fromY)) {
                return@mutatingOperation false
            }

            // Dwell at the origin. No events needed — the view's own long-press timer runs
            // from the DOWN it already received.
            if (holdMs > 0) {
                SystemClock.sleep(holdMs.toLong())
            }

            val steps = (durationMs / MOVE_INTERVAL_MS).coerceAtLeast(1)
            for (step in 1..steps) {
                val progress = step.toFloat() / steps
                val x = fromX + (toX - fromX) * progress
                val y = fromY + (toY - fromY) * progress
                val eventTime = SystemClock.uptimeMillis()
                if (!injectPointerEvent(MotionEvent.ACTION_MOVE, downTime, eventTime, x, y)) {
                    return@mutatingOperation false
                }
                SystemClock.sleep(MOVE_INTERVAL_MS.toLong())
            }

            // Settle at the destination before lifting so drop targets register the finish.
            SystemClock.sleep(DROP_SETTLE_MS)

            injectPointerEvent(
                MotionEvent.ACTION_UP,
                downTime,
                SystemClock.uptimeMillis(),
                toX,
                toY
            )
        }
    }

    private fun injectPointerEvent(
        action: Int,
        downTime: Long,
        eventTime: Long,
        x: Number,
        y: Number
    ): Boolean {
        val event = MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            x.toFloat(),
            y.toFloat(),
            0
        )
        // Injection is rejected unless the event claims a touchscreen source.
        event.source = InputDevice.SOURCE_TOUCHSCREEN
        return try {
            instrumentation.uiAutomation.injectInputEvent(event, true)
        } finally {
            event.recycle()
        }
    }

    fun scroll(direction: Direction, distance: Int): Boolean {
        return mutatingOperation {
            val (w, h) = device.displayWidth to device.displayHeight
            val cx = w / 2
            val cy = h / 2
            val steps = 20

            when (direction) {
                Direction.UP -> device.swipe(cx, cy, cx, cy + distance, steps)
                Direction.DOWN -> device.swipe(cx, cy, cx, cy - distance, steps)
                Direction.LEFT -> device.swipe(cx, cy, cx + distance, cy, steps)
                Direction.RIGHT -> device.swipe(cx, cy, cx - distance, cy, steps)
            }
        }
    }

    fun swipeInDirection(
        direction: Direction,
        distance: Int,
        durationMs: Int,
        resourceId: String?,
        text: String?
    ): Boolean {
        return mutatingOperation {
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
                    return@mutatingOperation device.swipe(cx, cy, cx + dx, cy + dy, steps)
                }
            }

            val cx = w / 2
            val cy = h / 2
            val (dx, dy) = directionDelta(direction, distance)
            device.swipe(cx, cy, cx + dx, cy + dy, steps)
        }
    }

    private fun directionDelta(direction: Direction, distance: Int): Pair<Int, Int> = when (direction) {
        Direction.UP -> 0 to -distance
        Direction.DOWN -> 0 to distance
        Direction.LEFT -> -distance to 0
        Direction.RIGHT -> distance to 0
    }

    // -- Text --

    fun typeText(text: String) {
        mutatingOperation {
            device.waitForIdle(2000)
            val focused = device.findObject(By.focused(true))
                ?: device.findObject(By.clazz("android.widget.EditText"))
            focused?.text = text
        }
    }

    fun clearText() {
        mutatingOperation {
            device.waitForIdle(2000)
            val focused = device.findObject(By.focused(true))
                ?: device.findObject(By.clazz("android.widget.EditText"))
            focused?.clear()
        }
    }

    fun setText(resourceId: String?, label: String?, containsText: String?, value: String): Boolean {
        return mutatingOperation {
            device.waitForIdle(2000)
            // `freshElements`, not `currentElements`: this mutating RPC queries inside its body.
            // Going through the caching path could expose pre-typing state to a concurrent query.
            // `freshElements` deliberately does not populate.
            val candidates = freshElements().filter { matches(it, resourceId, label, containsText) }
            // A label selector often hits the field's TextView first. Prefer an editable node.
            val target = candidates.firstOrNull { it.className?.contains("EditText") == true }
                ?: candidates.firstOrNull()
                ?: return@mutatingOperation false
            val before = target.text.orEmpty()
            target.click()
            target.text = value
            val after = target.text.orEmpty()
            // Password fields report masks, but their content still has to change.
            after == value || (value.isNotEmpty() && after.isNotEmpty() && after != before)
        }
    }

    // -- Navigation --

    fun pressBack(): Boolean = mutatingOperation { device.pressBack() }

    fun pressHome(): Boolean = mutatingOperation { device.pressHome() }

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
        return withCurrentElements { elements ->
            scopedElements(elements, appId)
                .filter { element ->
                    matches(element, resourceId, text, containsText)
                }
                .map { it.toSnapshot() }
                .filter { !labeledOnly || it.id.isNotBlank() || it.label.isNotBlank() }
        }
    }

    fun getAllElements(appId: String? = null): List<ElementSnapshot> {
        return withCurrentElements { elements ->
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
        return withCurrentElements { elements ->
            val matches = scopedElements(elements, appId)
                .filter { matches(it, resourceId, text, containsText) }
            matches.firstOrNull { it.isClickable }?.let { return@withCurrentElements it.toSnapshot() }
            matches.firstNotNullOfOrNull { nearestClickableAncestor(it) }
                ?.let { return@withCurrentElements it.toSnapshot() }
            matches.firstOrNull()?.toSnapshot()
        }
    }

    /** Walks up from [element] to the first clickable node, bounded so a deep tree cannot stall a tap. */
    private fun nearestClickableAncestor(element: UiObject2): UiObject2? {
        var current: UiObject2? = runCatching { element.parent }.getOrNull()
        var depth = 0
        while (current != null && depth < MAX_ANCESTOR_WALK) {
            if (current.isClickable) return current
            current = runCatching { current?.parent }.getOrNull()
            depth++
        }
        return null
    }

    /**
     * Elements from [appId]'s process, or every process when [appId] is null/blank.
     *
     * Unlike iOS's XCUITest, which isolates each app's accessibility tree behind
     * XCUIApplication(bundleIdentifier:), UIAutomator2's root query already returns every
     * visible window system-wide in one flat list — an app's own UI and system UI (permission
     * dialogs, the notification shade) mixed together. So scoping to [appId] is a filter, not a
     * separate lookup, and "fall back to system UI when nothing matches" falls out for free:
     * an empty filtered result just returns the unfiltered list, which already contains it.
     */
    private fun scopedElements(all: List<UiObject2>, appId: String?): List<UiObject2> {
        if (appId.isNullOrBlank()) return all
        val scoped = all.filter { it.applicationPackage == appId }
        return scoped.ifEmpty { all }
    }

    fun getInteractableElements(): List<ElementSnapshot> {
        return withCurrentElements { elements ->
            elements
                .filter { it.isClickable || it.isLongClickable || it.className?.contains("EditText") == true }
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
        invalidateElementCache()
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

    private fun UiObject2.toSnapshot(): ElementSnapshot {
        val bounds = visibleBounds ?: Rect()
        val contentDescription = contentDescription?.toString().orEmpty()
        val resourceName = resourceName.orEmpty()
        val textValue = text?.toString().orEmpty()
        val normalizedID = normalizedElementID(resourceName, contentDescription)

        return ElementSnapshot(
            id = normalizedID,
            label = textValue.ifBlank { contentDescription },
            value = textValue,
            type = className ?: "",
            frame = FrameRect(bounds.left, bounds.top, bounds.width(), bounds.height()),
            isEnabled = isEnabled,
            isVisible = true
        )
    }

    private fun matches(
        element: UiObject2,
        resourceId: String?,
        text: String?,
        containsText: String?
    ): Boolean {
        val elementText = element.text?.toString().orEmpty()
        val contentDescription = element.contentDescription?.toString().orEmpty()
        val resourceName = element.resourceName.orEmpty()
        val normalizedID = normalizedElementID(resourceName, contentDescription)

        if (resourceId != null && resourceId != normalizedID && resourceId != contentDescription && resourceId != resourceName) {
            return false
        }

        if (text != null && text != elementText && text != contentDescription) {
            return false
        }

        if (containsText != null && !elementText.contains(containsText) && !contentDescription.contains(containsText)) {
            return false
        }

        return resourceId != null || text != null || containsText != null
    }

    private fun normalizedElementID(resourceName: String, contentDescription: String): String {
        if (contentDescription.isNotBlank()) {
            return contentDescription
        }

        val resourceEntry = resourceName.substringAfterLast(':', resourceName).substringAfterLast('/')
        return resourceEntry.replace('_', '-')
    }

    private fun currentElements(): List<UiObject2> {
        val generation = synchronized(elementCacheLock) {
            cachedElements?.let { cached ->
                if (SystemClock.uptimeMillis() - cachedElementsAt < ELEMENT_CACHE_TTL_MS) return cached
            }
            elementCacheGeneration
        }

        val fresh = freshElements()
        synchronized(elementCacheLock) {
            // Never publish a tree whose collection overlapped an invalidation. The caller may
            // still use its own result, but later RPCs must fetch state from after the mutation.
            if (generation == elementCacheGeneration) {
                cachedElements = fresh
                cachedElementsAt = SystemClock.uptimeMillis()
            }
        }
        return fresh
    }

    /**
     * A UiObject2 is a live handle and any property access can throw after its backing node is
     * recycled. Retry the whole operation once with a fresh tree; partial results would make a
     * selector appear absent merely because its node changed during the walk.
     */
    private inline fun <T> withCurrentElements(operation: (List<UiObject2>) -> T): T {
        try {
            return operation(currentElements())
        } catch (_: StaleObjectException) {
            invalidateElementCache()
            return operation(currentElements())
        }
    }

    private fun freshElements(): List<UiObject2> {
        device.waitForIdle(WAIT_FOR_IDLE_MS)

        val roots = device.findObjects(By.depth(0)).ifEmpty {
            // Some emulator / API-level combinations return nothing from a depth-only selector
            // even with interactive-window retrieval enabled. Matching "any package" forces
            // ByMatcher to walk every window root it can reach.
            device.findObjects(By.pkg(ANY_PACKAGE))
        }

        if (roots.isEmpty()) {
            val automation = instrumentation.uiAutomation
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
