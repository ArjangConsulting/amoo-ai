package com.amoo.companion.bridge

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * The two finger paths of a pinch around a centre point, fitted inside the screen.
 *
 * Mirrors `Sources/AmooCore/PinchGesture.swift` (used by the iOS companion) so a pinch means the
 * same thing on both platforms. Fingers sit on a line through the centre on whichever axis has
 * more room and move between [startRadius] and [endRadius]. A scale above 1 spreads them (zoom
 * in); below 1 brings them together (zoom out). Radii are clamped so fingers stay on screen and
 * never closer than [MIN_RADIUS_DP], so an extreme scale is performed as far as it fits.
 */
class PinchGesture private constructor(
    val centerX: Float,
    val centerY: Float,
    val horizontal: Boolean,
    val startRadius: Float,
    val endRadius: Float,
    val durationMs: Long
) {
    fun fingers(radius: Float): Pair<Pair<Float, Float>, Pair<Float, Float>> =
        if (horizontal) {
            (centerX - radius to centerY) to (centerX + radius to centerY)
        } else {
            (centerX to centerY - radius) to (centerX to centerY + radius)
        }

    companion object {
        const val MIN_RADIUS_DP = 20f
        const val MAX_RADIUS_DP = 240f
        const val EDGE_MARGIN_DP = 8f
        const val DEFAULT_DURATION_MS = 600L
        const val MIN_DURATION_MS = 200L
        const val MAX_DURATION_MS = 3000L

        /**
         * Returns null when [scale] is not a finite positive number other than 1.
         *
         * @param velocity scale change per second; zero or negative uses the default duration.
         * @param bounds the frame the fingers stay inside: the pinched element's, or the screen.
         * @param density pixels per dp, so finger spacing is the same physical size on any screen.
         */
        fun fit(
            centerX: Float,
            centerY: Float,
            scale: Float,
            velocity: Float,
            bounds: android.graphics.RectF,
            density: Float
        ): PinchGesture? {
            if (!scale.isFinite() || scale <= 0f || scale == 1f) return null
            val minRadius = MIN_RADIUS_DP * density
            val margin = EDGE_MARGIN_DP * density
            val inset = minRadius + margin
            val x = clamp(centerX, bounds.left + inset, bounds.right - inset)
            val y = clamp(centerY, bounds.top + inset, bounds.bottom - inset)
            val horizontalRoom = min(x - bounds.left, bounds.right - x)
            val verticalRoom = min(y - bounds.top, bounds.bottom - y)
            val horizontal = horizontalRoom >= verticalRoom
            val room = min(max(horizontalRoom, verticalRoom) - margin, MAX_RADIUS_DP * density)
            val outer = max(room, minRadius)
            val (start, end) = if (scale > 1f) {
                max(minRadius, outer / scale) to outer
            } else {
                outer to max(minRadius, outer * scale)
            }
            val duration = if (velocity > 0f) (abs(scale - 1f) / velocity * 1000f).toLong() else DEFAULT_DURATION_MS
            return PinchGesture(x, y, horizontal, start, end, duration.coerceIn(MIN_DURATION_MS, MAX_DURATION_MS))
        }

        private fun clamp(value: Float, lower: Float, upper: Float): Float =
            if (lower > upper) (lower + upper) / 2f else value.coerceIn(lower, upper)
    }
}

/**
 * Injects a [PinchGesture] as one two-pointer touch stream: both fingers land, move in step, and
 * lift. UiAutomator's own `pinchOpen`/`pinchClose` only pinch around a found object's centre and
 * take a percentage rather than a scale, so the events are built directly to honour an arbitrary
 * centre and match the iOS companion.
 */
class PinchInjector(private val inject: (MotionEvent) -> Boolean) {

    fun perform(gesture: PinchGesture): Boolean {
        val downTime = SystemClock.uptimeMillis()
        val (startA, startB) = gesture.fingers(gesture.startRadius)
        if (!send(MotionEvent.ACTION_DOWN, downTime, listOf(startA))) return false
        if (!send(pointerAction(MotionEvent.ACTION_POINTER_DOWN), downTime, listOf(startA, startB))) {
            return false
        }
        SystemClock.sleep(LAND_MS)

        val steps = (gesture.durationMs / MOVE_INTERVAL_MS).toInt().coerceAtLeast(1)
        var last = startA to startB
        for (step in 1..steps) {
            val progress = step.toFloat() / steps
            val radius = gesture.startRadius + (gesture.endRadius - gesture.startRadius) * progress
            last = gesture.fingers(radius)
            if (!send(MotionEvent.ACTION_MOVE, downTime, listOf(last.first, last.second))) return false
            SystemClock.sleep(MOVE_INTERVAL_MS)
        }

        // Hold before lifting so the release doesn't add fling momentum to the zoom.
        SystemClock.sleep(SETTLE_MS)
        if (!send(pointerAction(MotionEvent.ACTION_POINTER_UP), downTime, listOf(last.first, last.second))) {
            return false
        }
        return send(MotionEvent.ACTION_UP, downTime, listOf(last.first))
    }

    /** A pointer-down/up action addressed to the second finger (pointer index 1). */
    private fun pointerAction(action: Int): Int = action or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)

    private fun send(action: Int, downTime: Long, points: List<Pair<Float, Float>>): Boolean {
        val properties = Array(points.size) { index ->
            MotionEvent.PointerProperties().apply {
                id = index
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(points.size) { index ->
            MotionEvent.PointerCoords().apply {
                x = points[index].first
                y = points[index].second
                pressure = 1f
                size = 1f
            }
        }
        val event = MotionEvent.obtain(
            downTime,
            SystemClock.uptimeMillis(),
            action,
            points.size,
            properties,
            coords,
            0,
            0,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_TOUCHSCREEN,
            0
        )
        return try {
            inject(event)
        } finally {
            event.recycle()
        }
    }

    private companion object {
        const val LAND_MS = 50L
        const val MOVE_INTERVAL_MS = 10L
        const val SETTLE_MS = 100L
    }
}
