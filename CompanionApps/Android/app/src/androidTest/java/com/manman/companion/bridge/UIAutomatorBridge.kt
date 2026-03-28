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
    private val device: UiDevice = UiDevice.getInstance(
        InstrumentationRegistry.getInstrumentation()
    )
    private val targetPackageName: String = InstrumentationRegistry.getInstrumentation().targetContext.packageName

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
            Direction.UP -> device.swipe(cx, cy, cx, cy - distance, steps)
            Direction.DOWN -> device.swipe(cx, cy, cx, cy + distance, steps)
            Direction.LEFT -> device.swipe(cx, cy, cx - distance, cy, steps)
            Direction.RIGHT -> device.swipe(cx, cy, cx + distance, cy, steps)
        }
    }

    // -- Text --

    fun typeText(text: String) {
        val focused = device.findObject(By.focused(true))
        focused?.text = text
    }

    fun clearText() {
        val focused = device.findObject(By.focused(true))
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
        val results = mutableListOf<ElementSnapshot>()

        val selector = when {
            resourceId != null -> By.res(resourceId)
            text != null -> By.text(text)
            containsText != null -> By.textContains(containsText)
            else -> By.pkg(currentPackageName())
        }

        device.findObjects(selector).forEach { element ->
            results.add(element.toSnapshot())
        }

        return results
    }

    fun getAllElements(): List<ElementSnapshot> {
        return device.findObjects(By.pkg(currentPackageName())).map { it.toSnapshot() }
    }

    fun getInteractableElements(): List<ElementSnapshot> {
        return device.findObjects(By.pkg(currentPackageName()))
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
        return ElementSnapshot(
            id = resourceName ?: "",
            label = text ?: contentDescription ?: "",
            value = text ?: "",
            type = className ?: "",
            frame = FrameRect(bounds.left, bounds.top, bounds.width(), bounds.height()),
            isEnabled = isEnabled,
            isVisible = true
        )
    }
}
