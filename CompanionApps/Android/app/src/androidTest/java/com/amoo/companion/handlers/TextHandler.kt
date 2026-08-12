package com.amoo.companion.handlers

import com.amoo.companion.bridge.UIAutomatorBridge

class TextHandler(private val bridge: UIAutomatorBridge) {

    fun typeText(text: String) {
        bridge.typeText(text)
    }

    fun clearText() {
        bridge.clearText()
    }
}
