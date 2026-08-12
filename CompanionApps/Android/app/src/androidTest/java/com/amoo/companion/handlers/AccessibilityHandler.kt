package com.amoo.companion.handlers

import com.amoo.companion.bridge.ElementSnapshot
import com.amoo.companion.bridge.UIAutomatorBridge

class AccessibilityHandler(private val bridge: UIAutomatorBridge) {

    fun findElements(
        resourceId: String?,
        text: String?,
        containsText: String?
    ): List<ElementSnapshot> {
        return bridge.findElements(resourceId, text, containsText)
    }

    fun isKeyboardVisible(): Boolean = bridge.isKeyboardVisible()

    fun takeScreenshot(): ByteArray = bridge.takeScreenshot()

    fun getAllElements(): List<ElementSnapshot> = bridge.getAllElements()

    fun getInteractableElements(): List<ElementSnapshot> = bridge.getInteractableElements()

    fun findByDescription(description: String): List<ElementSnapshot> = bridge.findByDescription(description)
}
