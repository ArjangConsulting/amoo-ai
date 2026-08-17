package com.amoo.companion.handlers

import com.amoo.companion.bridge.ElementSnapshot
import com.amoo.companion.bridge.UIAutomatorBridge

class AccessibilityHandler(private val bridge: UIAutomatorBridge) {

    fun findElements(
        resourceId: String?,
        text: String?,
        containsText: String?,
        appId: String? = null,
        labeledOnly: Boolean = false
    ): List<ElementSnapshot> {
        return bridge.findElements(resourceId, text, containsText, appId, labeledOnly)
    }

    fun isKeyboardVisible(): Boolean = bridge.isKeyboardVisible()

    fun currentPackageName(): String = bridge.currentPackageName()

    fun targetPackageNameBinding(): String? = bridge.targetPackageNameBinding()

    fun setTargetPackageName(bundleId: String?) = bridge.setTargetPackageName(bundleId)

    fun screenWidth(): Int = bridge.screenWidth()

    fun screenHeight(): Int = bridge.screenHeight()

    fun takeScreenshot(): ByteArray = bridge.takeScreenshot()

    fun getAllElements(appId: String? = null): List<ElementSnapshot> = bridge.getAllElements(appId)

    fun getInteractableElements(): List<ElementSnapshot> = bridge.getInteractableElements()

    fun findByDescription(description: String): List<ElementSnapshot> = bridge.findByDescription(description)
}
