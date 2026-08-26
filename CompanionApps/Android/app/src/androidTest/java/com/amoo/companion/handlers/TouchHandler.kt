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

    fun tapElement(
        resourceId: String?,
        text: String?,
        containsText: String? = null,
        appId: String? = null
    ): Boolean {
        // findTapTarget rather than findElements: on Compose the node that matches a label or text
        // is often not the node that can be clicked. See its documentation.
        val target = bridge.findTapTarget(resourceId, text, containsText, appId) ?: return false
        return bridge.tap(
            target.frame.x + target.frame.width / 2,
            target.frame.y + target.frame.height / 2
        )
    }
}
