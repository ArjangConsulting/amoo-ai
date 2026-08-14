package com.amoo.companion.handlers

import com.amoo.companion.bridge.UIAutomatorBridge

class TextHandler(private val bridge: UIAutomatorBridge) {

    fun typeText(text: String) {
        bridge.typeText(text)
    }

    fun clearText() {
        bridge.clearText()
    }

    fun setText(resourceId: String?, label: String?, containsText: String?, value: String): Boolean {
        return bridge.setText(resourceId, label, containsText, value)
    }
}
