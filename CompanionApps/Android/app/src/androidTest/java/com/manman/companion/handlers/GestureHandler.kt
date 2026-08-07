package com.manman.companion.handlers

import com.manman.companion.bridge.Direction
import com.manman.companion.bridge.UIAutomatorBridge

class GestureHandler(private val bridge: UIAutomatorBridge) {

    fun swipe(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int): Boolean {
        val steps = (durationMs / 5).coerceAtLeast(1)
        return bridge.swipe(fromX, fromY, toX, toY, steps)
    }

    fun drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int, holdMs: Int): Boolean {
        return bridge.drag(fromX, fromY, toX, toY, durationMs, holdMs)
    }

    fun scroll(direction: Direction, distance: Int): Boolean {
        return bridge.scroll(direction, distance)
    }

    fun swipeInDirection(
        direction: Direction,
        distance: Int,
        durationMs: Int,
        resourceId: String?,
        text: String?
    ): Boolean {
        return bridge.swipeInDirection(direction, distance, durationMs, resourceId, text)
    }
}
