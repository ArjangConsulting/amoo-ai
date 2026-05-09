package com.manman.companion.bridge

import android.graphics.Rect
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2

/**
 * Single point of contact with Android's UIAutomator2 framework.
 * If UIAutomator APIs change, only this file changes.
 */
class UIAutomatorBridge {
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
