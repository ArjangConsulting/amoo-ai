package com.manman.companion.handlers

import com.manman.companion.bridge.UIAutomatorBridge

class TextHandler(private val bridge: UIAutomatorBridge) {

    fun typeText(text: String) {
        bridge.typeText(text)
    }

    fun clearText() {
        bridge.clearText()
    }
}
