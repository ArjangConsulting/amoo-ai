import StudioProtocol

/// `drag` and `pinch` for the Espresso (Views) emitter.
///
/// Espresso has neither gesture built in, so the generated test carries two small `ViewAction`s
/// that inject touches through Espresso's own `UiController`. They need no dependency beyond
/// espresso-core and replay the gestures the live tools perform: a drag holds at the source long
/// enough to lift the item before moving, and a pinch moves two fingers about the view's centre.
extension EspressoEmitter {
    static func dragStatement(for operation: StudioToolOperation) throws -> String {
        let timing = try DragArguments(operation)
        let source = try matcher(operation)
        let target = try matcher(operation.dropTarget)
        let timeout = try timeoutMilliseconds(for: operation)
        return """
        \(indent)onView(isRoot()).perform(waitUntilDisplayed(\(source), \(timeout)L))
        \(indent)onView(isRoot()).perform(waitUntilDisplayed(\(target), \(timeout)L))
        \(indent)onView(\(source)).perform(dragOnto(\(target), \(timing.holdMilliseconds)L, \(
            timing.durationMilliseconds
        )L))
        """
    }

    static func pinchStatement(for operation: StudioToolOperation) throws -> String {
        let pinch = try PinchArguments(operation)
        let action = "pinch(\(pinch.scale)f, \(pinch.durationMilliseconds)L)"
        guard PinchArguments.targetsElement(operation) else {
            return "\(indent)onView(isRoot()).perform(\(action))"
        }
        let target = try matcher(operation)
        return try """
        \(indent)onView(isRoot()).perform(waitUntilDisplayed(\(target), \(timeoutMilliseconds(for: operation))L))
        \(indent)onView(\(target)).perform(\(action))
        """
    }

    /// Whether any operation needs the gesture helpers below.
    static func needsGestureHelpers(_ operations: [StudioToolOperation]) -> Bool {
        operations.contains { [StudioTool.drag.rawValue, StudioTool.pinch.rawValue].contains($0.tool) }
    }

    static let gestureImports = "\nimport android.view.InputDevice\nimport android.view.MotionEvent"

    static let gestureHelpers: String = {
        let raw = """
        // Presses the view, holds so a drag-and-drop interaction lifts it, moves it onto the first
        // displayed view matching `target`, and releases it there.
        private fun dragOnto(target: Matcher<View>, holdMillis: Long, travelMillis: Long): ViewAction {
            return object : ViewAction {
                override fun getConstraints(): Matcher<View> = isDisplayed()

                override fun getDescription(): String = "drag onto a view matching $target"

                override fun perform(uiController: UiController, view: View) {
                    val drop = TreeIterables.breadthFirstViewTraversal(view.rootView)
                        .firstOrNull { target.matches(it) && isDisplayed().matches(it) }
                        ?: throw PerformException.Builder()
                            .withActionDescription(description)
                            .withViewDescription(HumanReadables.describe(view))
                            .withCause(IllegalStateException("no displayed drop target matching $target"))
                            .build()
                    val start = screenCentre(view)
                    val end = screenCentre(drop)
                    val downTime = SystemClock.uptimeMillis()
                    injectTouch(uiController, downTime, MotionEvent.ACTION_DOWN, listOf(start))
                    uiController.loopMainThreadForAtLeast(holdMillis)
                    val steps = (travelMillis / 10).coerceAtLeast(1)
                    for (step in 1..steps) {
                        val fraction = step.toFloat() / steps
                        val point = floatArrayOf(
                            start[0] + (end[0] - start[0]) * fraction,
                            start[1] + (end[1] - start[1]) * fraction
                        )
                        injectTouch(uiController, downTime, MotionEvent.ACTION_MOVE, listOf(point))
                        uiController.loopMainThreadForAtLeast(10)
                    }
                    uiController.loopMainThreadForAtLeast(200)
                    injectTouch(uiController, downTime, MotionEvent.ACTION_UP, listOf(end))
                }
            }
        }

        // Two fingers either side of the view's centre spread apart (scale > 1, zoom in) or come
        // together (scale < 1, zoom out) over durationMillis.
        private fun pinch(scale: Float, durationMillis: Long): ViewAction {
            return object : ViewAction {
                override fun getConstraints(): Matcher<View> = isDisplayed()

                override fun getDescription(): String = "pinch to scale $scale"

                override fun perform(uiController: UiController, view: View) {
                    val centre = screenCentre(view)
                    val density = view.resources.displayMetrics.density
                    val horizontal = view.width >= view.height
                    val minimum = 20 * density
                    val outer = maxOf((if (horizontal) view.width else view.height) / 2f - 8 * density, minimum)
                    val from = if (scale > 1f) maxOf(minimum, outer / scale) else outer
                    val to = if (scale > 1f) outer else maxOf(minimum, outer * scale)
                    fun fingers(radius: Float): List<FloatArray> = if (horizontal) {
                        listOf(floatArrayOf(centre[0] - radius, centre[1]), floatArrayOf(centre[0] + radius, centre[1]))
                    } else {
                        listOf(floatArrayOf(centre[0], centre[1] - radius), floatArrayOf(centre[0], centre[1] + radius))
                    }
                    val secondFinger = 1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT
                    val downTime = SystemClock.uptimeMillis()
                    var current = fingers(from)
                    injectTouch(uiController, downTime, MotionEvent.ACTION_DOWN, current.take(1))
                    injectTouch(uiController, downTime, MotionEvent.ACTION_POINTER_DOWN or secondFinger, current)
                    uiController.loopMainThreadForAtLeast(50)
                    val steps = (durationMillis / 10).coerceAtLeast(1)
                    for (step in 1..steps) {
                        current = fingers(from + (to - from) * (step.toFloat() / steps))
                        injectTouch(uiController, downTime, MotionEvent.ACTION_MOVE, current)
                        uiController.loopMainThreadForAtLeast(10)
                    }
                    uiController.loopMainThreadForAtLeast(100)
                    injectTouch(uiController, downTime, MotionEvent.ACTION_POINTER_UP or secondFinger, current)
                    injectTouch(uiController, downTime, MotionEvent.ACTION_UP, current.take(1))
                }
            }
        }

        private fun screenCentre(view: View): FloatArray {
            val location = IntArray(2)
            view.getLocationOnScreen(location)
            return floatArrayOf(location[0] + view.width / 2f, location[1] + view.height / 2f)
        }

        // One touch event with a finger at each point, injected and recycled.
        private fun injectTouch(uiController: UiController, downTime: Long, action: Int, points: List<FloatArray>) {
            val properties = Array(points.size) { index ->
                MotionEvent.PointerProperties().apply {
                    id = index
                    toolType = MotionEvent.TOOL_TYPE_FINGER
                }
            }
            val coords = Array(points.size) { index ->
                MotionEvent.PointerCoords().apply {
                    x = points[index][0]
                    y = points[index][1]
                    pressure = 1f
                    size = 1f
                }
            }
            val event = MotionEvent.obtain(
                downTime, SystemClock.uptimeMillis(), action, points.size, properties, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0
            )
            try {
                uiController.injectMotionEvent(event)
            } finally {
                event.recycle()
            }
        }
        """
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    \($0)" }
            .joined(separator: "\n")
    }()
}
