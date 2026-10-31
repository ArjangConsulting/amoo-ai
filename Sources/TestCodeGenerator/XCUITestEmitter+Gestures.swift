import StudioProtocol

extension XCUITestEmitter {
    /// A `drag` or `pinch` operation; anything else is not a gesture this file emits.
    static func gestureStatement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        switch operation.tool {
        case StudioTool.drag.rawValue:
            try dragStatement(for: operation, context: context, localNames: &localNames, lookups: &lookups)
        case StudioTool.pinch.rawValue:
            try pinchStatement(for: operation, context: context, localNames: &localNames, lookups: &lookups)
        default:
            throw TestCodeGeneratorError.unsupportedTool(operation.tool)
        }
    }

    /// Presses the source element, holds long enough for a drag-and-drop interaction to lift it,
    /// moves it slowly onto the target, and dwells there before releasing, which is the same gesture
    /// the live `drag` tool performs.
    static func dragStatement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        let timing = try DragArguments(operation)
        let (_, source, sourceDeclaration) = try lookup(
            operation, context: context, localNames: &localNames, lookups: &lookups
        )
        let (_, target, targetDeclaration) = try lookup(
            operation.dropTarget, context: context, localNames: &localNames, lookups: &lookups
        )
        let drag = "\(source).press(forDuration: \(timing.holdSeconds), thenDragTo: \(target),"
            + " withVelocity: .slow, thenHoldForDuration: 0.2)"
        return try """
        \(sourceDeclaration)
        \(targetDeclaration)
        \(indent)\(waitCall("waitForHittability", source, operation, context: context))
        \(indent)\(waitCall("waitForExistence", target, operation, context: context))
        \(indent)\(drag)
        """
    }

    /// Pinches the element, or the whole app when the recording named none.
    static func pinchStatement(
        for operation: StudioToolOperation,
        context: StudioTestContext?,
        localNames: inout LocalNameAllocator,
        lookups: inout [String: String]
    ) throws -> String {
        let pinch = try PinchArguments(operation)
        let call = "pinch(withScale: \(pinch.scale), velocity: \(pinch.signedVelocity))"
        guard PinchArguments.targetsElement(operation) else {
            return "\(indent)app.\(call)"
        }
        let (_, variable, declaration) = try lookup(
            operation, context: context, localNames: &localNames, lookups: &lookups
        )
        return try """
        \(declaration)
        \(indent)\(waitCall("waitForHittability", variable, operation, context: context))
        \(indent)\(variable).\(call)
        """
    }
}
