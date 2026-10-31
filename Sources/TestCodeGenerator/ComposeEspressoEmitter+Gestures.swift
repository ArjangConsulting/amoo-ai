import StudioProtocol

/// `drag` and `pinch` for the Compose emitter, through `performTouchInput`, replaying the gestures
/// the live tools perform: a drag holds at the source long enough to lift the item before moving
/// onto the target, and a pinch moves two fingers about the node's centre.
extension ComposeEspressoEmitter {
    static func dragStatement(for operation: StudioToolOperation) throws -> String {
        let timing = try DragArguments(operation)
        let source = try guardedNode(operation)
        let target = try guardedNode(operation.dropTarget)
        return """
        \(source.wait)
        \(target.wait)
        \(indent)run {
        \(indent)    val dropAt = \(target.node).fetchSemanticsNode().boundsInRoot.center
        \(indent)    val origin = \(source.node).fetchSemanticsNode().boundsInRoot.topLeft
        \(indent)    \(source.node).assertIsDisplayed().performTouchInput {
        \(indent)        val end = dropAt - origin
        \(indent)        down(center)
        \(indent)        advanceEventTime(\(timing.holdMilliseconds)L)
        \(indent)        val steps = \(max(timing.durationMilliseconds / 16, 1))
        \(indent)        for (step in 1..steps) {
        \(indent)            moveTo(center + (end - center) * (step.toFloat() / steps), delayMillis = 16L)
        \(indent)        }
        \(indent)        advanceEventTime(200L)
        \(indent)        up()
        \(indent)    }
        \(indent)}
        """
    }

    static func pinchStatement(for operation: StudioToolOperation) throws -> String {
        let pinch = try PinchArguments(operation)
        let radii = pinch.scale > 1
            ? (from: "maxOf(minimum, outer / \(pinch.scale)f)", to: "outer")
            : (from: "outer", to: "maxOf(minimum, outer * \(pinch.scale)f)")
        let gesture = """
        performTouchInput {
        \(indent)    val horizontal = width >= height
        \(indent)    val minimum = 20f * density
        \(indent)    val outer = maxOf((if (horizontal) width else height) / 2f - 8f * density, minimum)
        \(indent)    val from = \(radii.from)
        \(indent)    val to = \(radii.to)
        \(indent)    val axis = if (horizontal) Offset(1f, 0f) else Offset(0f, 1f)
        \(indent)    pinch(center - axis * from, center - axis * to, center + axis * from, center + axis * to, \(
            pinch.durationMilliseconds
        )L)
        \(indent)}
        """
        guard PinchArguments.targetsElement(operation) else {
            return "\(indent)composeTestRule.onRoot().\(gesture)"
        }
        let target = try guardedNode(operation)
        return "\(target.wait)\n\(indent)\(target.node).assertIsDisplayed().\(gesture)"
    }

    static func gestureImports(_ operations: [StudioToolOperation]) -> String {
        guard operations.contains(where: { $0.tool == StudioTool.pinch.rawValue }) else { return "" }
        return "\nimport androidx.compose.ui.geometry.Offset\nimport androidx.compose.ui.test.pinch"
    }
}
