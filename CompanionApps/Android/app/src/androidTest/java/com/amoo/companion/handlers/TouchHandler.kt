package com.amoo.companion.handlers

import com.amoo.companion.bridge.UIAutomatorBridge

class TouchHandler(private val bridge: UIAutomatorBridge) {

    fun tap(x: Int, y: Int): Boolean = bridge.tap(x, y)

    fun doubleTap(x: Int, y: Int): Boolean {
        bridge.tap(x, y)
        Thread.sleep(50)
        return bridge.tap(x, y)
    }

    fun longPress(x: Int, y: Int, durationMs: Int): Boolean {
        return bridge.longPress(x, y, durationMs)
    }

    fun tapElement(resourceId: String?, text: String?, appId: String? = null): Boolean {
        val elements = bridge.findElements(resourceId, text, null, appId)
        val first = elements.firstOrNull() ?: return false
        return bridge.tap(
            first.frame.x + first.frame.width / 2,
            first.frame.y + first.frame.height / 2
        )
    }
}
