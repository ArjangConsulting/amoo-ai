package com.amoo.companion.bridge

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2

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
    }

    private val instrumentation by lazy(LazyThreadSafetyMode.NONE) {
        InstrumentationRegistry.getInstrumentation()
    }
    private val device by lazy(LazyThreadSafetyMode.NONE) {
        UiDevice.getInstance(instrumentation)
    }
    private val targetPackageName by lazy(LazyThreadSafetyMode.NONE) {
        instrumentation.targetContext.packageName
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
        val candidates = currentElements().filter { matches(it, resourceId, label, containsText) }
        // A selector matching by label usually hits the field's own TextView label first, and
        // setting text on that silently does nothing. Prefer an actual editable node.
        val target = candidates.firstOrNull { it.className?.contains("EditText") == true }
            ?: candidates.firstOrNull()
            ?: return false
        val before = target.text.orEmpty()
        target.click()
        target.text = value
        val after = target.text.orEmpty()
        // A password field reports a mask rather than what was typed, so an exact match is not
        // always available — but the content still has to have moved off what was there before.
        return after == value || (value.isNotEmpty() && after.isNotEmpty() && after != before)
    }

    // -- Navigation --

    fun pressBack(): Boolean = device.pressBack()

    fun pressHome(): Boolean = device.pressHome()

    // -- Accessibility --

    fun findElements(
        resourceId: String?,
        text: String?,
        containsText: String?
    ): List<ElementSnapshot> {
        return currentElements()
            .filter { element ->
                matches(element, resourceId, text, containsText)
            }
            .map { it.toSnapshot() }
    }

    fun getAllElements(): List<ElementSnapshot> {
        return currentElements().map { it.toSnapshot() }
    }

    fun getInteractableElements(): List<ElementSnapshot> {
        return currentElements()
            .filter { it.isClickable || it.isLongClickable || it.className?.contains("EditText") == true }
            .map { it.toSnapshot() }
    }

    fun findByDescription(description: String): List<ElementSnapshot> {
        val query = description.lowercase()
        return getAllElements().filter { snapshot ->
            snapshot.id.lowercase().contains(query) || snapshot.label.lowercase().contains(query)
        }
    }

    fun currentPackageName(): String {
        return device.currentPackageName ?: targetPackageName
    }

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
        return device.findObjects(By.depth(0))
            .flatMap { root -> sequenceOf(root) + root.children.asSequence().flatMap { collectDescendants(it) } }
            .toList()
    }

    private fun collectDescendants(node: UiObject2): Sequence<UiObject2> {
        return sequenceOf(node) + node.children.asSequence().flatMap { child -> collectDescendants(child) }
    }
}
