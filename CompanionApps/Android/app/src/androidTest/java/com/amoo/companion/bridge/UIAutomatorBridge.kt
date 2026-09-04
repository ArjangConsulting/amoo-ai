package com.amoo.companion.bridge

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
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

        /** Bounds the accessibility walk so a pathological tree cannot stall a query. */
        const val MAX_TREE_DEPTH = 60

        /** Quiescence wait before reading the hierarchy, so a mid-transition frame is not captured. */
        const val WAIT_FOR_IDLE_MS = 2_000L

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
            val automation = instrumentation.uiAutomation
            val info = automation.serviceInfo ?: return
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo = info
        }.onFailure { Log.w(LOG_TAG, "Could not enable interactive-window retrieval", it) }
    }

    // -- Touch --

    fun tap(x: Int, y: Int): Boolean = device.click(x, y)

    fun longPress(x: Int, y: Int, durationMs: Int): Boolean {
        return device.swipe(x, y, x, y, durationMs / 5) // swipe in-place simulates long press
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
    fun drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int, holdMs: Int): Boolean {
        val downTime = SystemClock.uptimeMillis()

        if (!injectPointerEvent(MotionEvent.ACTION_DOWN, downTime, downTime, fromX, fromY)) {
            return false
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
                return false
            }
            SystemClock.sleep(MOVE_INTERVAL_MS.toLong())
        }

        // Settle at the destination before lifting so drop targets register the finish.
        SystemClock.sleep(DROP_SETTLE_MS)

        return injectPointerEvent(
            MotionEvent.ACTION_UP,
            downTime,
            SystemClock.uptimeMillis(),
            toX,
            toY
        )
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
        val (w, h) = device.displayWidth to device.displayHeight
        val cx = w / 2
        val cy = h / 2
        val steps = 20

        return when (direction) {
            Direction.UP -> device.swipe(cx, cy, cx, cy + distance, steps)
            Direction.DOWN -> device.swipe(cx, cy, cx, cy - distance, steps)
            Direction.LEFT -> device.swipe(cx, cy, cx + distance, cy, steps)
            Direction.RIGHT -> device.swipe(cx, cy, cx - distance, cy, steps)
        }
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
        device.waitForIdle(2000)
        // The only path that still needs live [UiObject2] handles: the others just read the tree,
        // but this one has to type into the node it finds. Its per-node property reads are the cost
        // documented on [NodeRecord], which is acceptable for a single text entry and not for a
        // query issued after every action.
        val candidates = uiObjectTree().filter { uiMatches(it, resourceId, label, containsText) }
        // A label selector often hits the field's TextView first. Prefer an editable node.
        val target = candidates.firstOrNull { it.className?.contains("EditText") == true }
            ?: candidates.firstOrNull()
            ?: return false
        val before = target.text.orEmpty()
        target.click()
        target.text = value
        val after = target.text.orEmpty()
        // Password fields report masks, but their content still has to change.
        return after == value || (value.isNotEmpty() && after.isNotEmpty() && after != before)
    }

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
            instrumentation.uiAutomation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
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
     * separate lookup, and "fall back to system UI when nothing matches" falls out for free:
     * an empty filtered result just returns the unfiltered list, which already contains it.
     */
    private fun scopedElements(all: List<NodeRecord>, appId: String?): List<NodeRecord> {
        if (appId.isNullOrBlank()) return all
        val scoped = all.filter { it.packageName == appId }
        return scoped.ifEmpty { all }
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

    private fun NodeRecord.toSnapshot(): ElementSnapshot = ElementSnapshot(
        id = id,
        label = label,
        value = value,
        type = type,
        frame = FrameRect(bounds.left, bounds.top, bounds.width(), bounds.height()),
        isEnabled = isEnabled,
        isVisible = isVisible
    )

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

        if (text != null && text != elementText && text != contentDescription) {
            return false
        }

        if (containsText != null && !elementText.contains(containsText) && !contentDescription.contains(containsText)) {
            return false
        }

        // No selector means "everything on screen", which is how an icon-only control with neither
        // id nor label is found at all — `find_elements` with no arguments is the documented way in
        // (see skills/driving-amoo). This used to return false here, so that call answered 0
        // elements on Android while iOS listed the whole tree.
        return true
    }

    private fun normalizedElementID(resourceName: String, contentDescription: String): String {
        if (contentDescription.isNotBlank()) {
            return contentDescription
        }

        val resourceEntry = resourceName.substringAfterLast(':', resourceName).substringAfterLast('/')
        return resourceEntry.replace('_', '-')
    }

    /**
     * A UiObject2 is a live handle and any property access can throw after its backing node is
     * recycled. Retry the whole operation once with a fresh tree; partial results would make a
     * selector appear absent merely because its node changed during the walk.
     */
    private inline fun <T> withCurrentElements(operation: (List<NodeRecord>) -> T): T {
        try {
            return operation(currentElements())
        } catch (_: StaleObjectException) {
            return operation(currentElements())
        }
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
        val id: String,
        val label: String,
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
        /**
         * Nearest clickable ancestor, resolved while walking rather than by climbing `parent`
         * afterwards — a parent walk is another IPC per step, and the walk already knows the
         * answer. Compose needs this: a Button becomes sibling semantics nodes where the one
         * carrying the text is not the one that is clickable.
         */
        val clickableAncestor: NodeRecord? = null
    )

    private fun currentElements(): List<NodeRecord> {
        device.waitForIdle(WAIT_FOR_IDLE_MS)
        val automation = instrumentation.uiAutomation
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
        val windows = runCatching { automation.windows }.getOrNull().orEmpty()
        val roots = windows.mapNotNull { it.root }
            .ifEmpty { listOfNotNull(automation.rootInActiveWindow) }

        if (roots.isEmpty()) {
            Log.w(
                LOG_TAG,
                "currentElements found no window roots. " +
                    "serviceInfoFlags=${automation.serviceInfo?.flags} " +
                    "currentPackage=${device.currentPackageName}"
            )
        }

        val out = ArrayList<NodeRecord>()
        try {
            for (root in roots) {
                collectRecords(root, nearestClickable = null, depth = 0, into = out)
            }
        } finally {
            for (root in roots) root.recycleQuietly()
            for (window in windows) runCatching { window.recycle() }
        }
        return out
    }

    private fun collectRecords(
        node: AccessibilityNodeInfo,
        nearestClickable: NodeRecord?,
        depth: Int,
        into: MutableList<NodeRecord>
    ) {
        if (depth > MAX_TREE_DEPTH) return
        val record = runCatching { node.toRecord(nearestClickable) }.getOrNull() ?: return
        into.add(record)
        val ancestorForChildren = if (record.isClickable) record else nearestClickable
        for (index in 0 until node.childCount) {
            val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
            try {
                collectRecords(child, ancestorForChildren, depth + 1, into)
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

    private fun AccessibilityNodeInfo.toRecord(nearestClickable: NodeRecord?): NodeRecord {
        val rect = Rect().also { getBoundsInScreen(it) }
        val contentDescription = contentDescription?.toString().orEmpty()
        val resourceName = viewIdResourceName.orEmpty()
        val textValue = text?.toString().orEmpty()
        return NodeRecord(
            id = normalizedElementID(resourceName, contentDescription),
            label = textValue.ifBlank { contentDescription },
            value = textValue,
            type = className?.toString().orEmpty(),
            contentDescription = contentDescription,
            resourceName = resourceName,
            packageName = packageName?.toString().orEmpty(),
            bounds = rect,
            isEnabled = isEnabled,
            isVisible = isVisibleToUser,
            isClickable = isClickable,
            isLongClickable = isLongClickable,
            clickableAncestor = nearestClickable
        )
    }

    /** [matches] over a live handle. Only [setText] needs this; see the note there. */
    private fun uiMatches(
        element: UiObject2,
        resourceId: String?,
        text: String?,
        containsText: String?
    ): Boolean {
        val elementText = runCatching { element.text?.toString() }.getOrNull().orEmpty()
        val contentDescription = runCatching { element.contentDescription?.toString() }.getOrNull().orEmpty()
        val resourceName = runCatching { element.resourceName }.getOrNull().orEmpty()
        val normalizedID = normalizedElementID(resourceName, contentDescription)

        if (resourceId != null && resourceId != normalizedID &&
            resourceId != contentDescription && resourceId != resourceName
        ) {
            return false
        }
        if (text != null && text != elementText && text != contentDescription) {
            return false
        }
        if (containsText != null && !elementText.contains(containsText) &&
            !contentDescription.contains(containsText)
        ) {
            return false
        }
        return true
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
