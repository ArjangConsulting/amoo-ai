import StudioProtocol

/// The validated timing of a `drag` operation, shared by every emitter so a recorded drag means the
/// same gesture in XCUITest, Espresso and Compose.
struct DragArguments: Equatable {
    /// Hold at the source before moving. Long enough for a drag-and-drop interaction to lift the item
    /// (iOS's drag lift and Android's long-press timeout are both ~500ms).
    static let defaultHoldMilliseconds = 800
    static let defaultDurationMilliseconds = 1000

    let holdMilliseconds: Int
    let durationMilliseconds: Int

    init(_ operation: StudioToolOperation) throws {
        guard operation.hasSelector(),
              operation.hasSelector(prefix: StudioToolOperation.dropTargetPrefix)
        else {
            throw TestCodeGeneratorError.missingArgument(
                tool: operation.tool,
                argument: "a source (id, label or contains_text) and a target (to_id, to_label or to_contains_text)"
            )
        }
        holdMilliseconds = try Self.milliseconds(
            operation, key: PlanArgument.holdMilliseconds.rawValue, default: Self.defaultHoldMilliseconds
        )
        durationMilliseconds = try Self.milliseconds(
            operation, key: PlanArgument.durationMilliseconds.rawValue, default: Self.defaultDurationMilliseconds
        )
    }

    var holdSeconds: Double {
        Double(holdMilliseconds) / 1000
    }

    private static func milliseconds(_ operation: StudioToolOperation, key: String, default value: Int) throws -> Int {
        guard let raw = operation.arguments[key] else { return value }
        guard let parsed = Int(raw), parsed >= 0 else {
            throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: key, value: raw)
        }
        return parsed
    }
}

/// The validated `scale` and speed of a `pinch` operation.
struct PinchArguments: Equatable {
    /// Scale change per second when the recording gave no velocity.
    static let defaultSpeed = 1.0

    /// Ratio of finger separation at the end to the start: above 1 zooms in, below 1 zooms out.
    let scale: Double
    /// Unsigned scale change per second.
    let speed: Double

    init(_ operation: StudioToolOperation) throws {
        guard let raw = operation.arguments[PlanArgument.scale.rawValue] else {
            throw TestCodeGeneratorError.missingArgument(tool: operation.tool, argument: "scale")
        }
        guard let scale = Double(raw), scale.isFinite, scale > 0, scale != 1 else {
            throw TestCodeGeneratorError.invalidArgument(tool: operation.tool, argument: "scale", value: raw)
        }
        self.scale = scale
        if let rawVelocity = operation.arguments[PlanArgument.velocity.rawValue] {
            guard let velocity = Double(rawVelocity), velocity.isFinite else {
                throw TestCodeGeneratorError.invalidArgument(
                    tool: operation.tool, argument: "velocity", value: rawVelocity
                )
            }
            speed = velocity == 0 ? Self.defaultSpeed : abs(velocity)
        } else {
            speed = Self.defaultSpeed
        }
    }

    /// XCUITest's velocity: positive to zoom in, negative to zoom out, or it rejects the gesture.
    var signedVelocity: Double {
        scale > 1 ? speed : -speed
    }

    /// How long the fingers travel, for frameworks that take a duration instead of a velocity.
    var durationMilliseconds: Int {
        let seconds = abs(scale - 1) / speed
        return Int((min(max(seconds, 0.2), 3.0) * 1000).rounded())
    }

    /// Whether the pinch targets an element; otherwise it pinches the whole app.
    static func targetsElement(_ operation: StudioToolOperation) -> Bool {
        operation.hasSelector()
    }
}
