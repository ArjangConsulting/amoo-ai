package com.amoo.companion.bridge

data class ElementSnapshot(
    val id: String,
    val label: String,
    val value: String,
    val type: String,
    val frame: FrameRect,
    val isEnabled: Boolean,
    val isVisible: Boolean,
    val isSecureTextEntry: Boolean = false,
    /** Input hint TalkBack announces for an empty field; null when the node has none. */
    val placeholder: String? = null
)
