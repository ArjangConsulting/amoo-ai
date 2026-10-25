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

    fun inspectAccessibility(
        request: amoo.v1.AccessibilityInspectionRequest, isCancelled: () -> Boolean = { false }
    ): amoo.v1.AccessibilityInspectionResponse {
        val result = when (request.operation) {
            "nativeAudit" -> com.amoo.companion.bridge.NativeAccessibilityInspector(bridge).audit(request, isCancelled)
            "talkBack" -> com.amoo.companion.bridge.TalkBackInspector(bridge).inspect(request, isCancelled)
            else -> amoo.v1.AccessibilityInspectionResponse.newBuilder()
                .setProvider("android").setStatus("unsupported")
                .setError("Requested accessibility provider is unavailable on Android").build()
        }
        return result.toBuilder().putAllProvenance(
            com.amoo.companion.bridge.AccessibilityProvenance.capture(request.appId)
        ).build()
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
