// swiftlint:disable multiline_arguments
import Foundation

public struct RecordedElement: Sendable, Codable, Equatable {
    public let id: String?
    public let label: String?
    public let elementType: String?
    public let frame: RecordedRect?
    public let hitPoint: RecordedPoint?

    public init(
        id: String?,
        label: String?,
        elementType: String? = nil,
        frame: RecordedRect?,
        hitPoint: RecordedPoint?
    ) {
        self.id = id
        self.label = label
        self.elementType = elementType
        self.frame = frame
        self.hitPoint = hitPoint
    }
}

public struct RecordedPoint: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x; self.y = y
    }
}

public struct RecordedRect: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func contains(_ point: RecordedPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
}

public struct RecordedGestureTarget: Sendable, Codable, Equatable {
    public enum Resolution: String, Sendable, Codable { case frameContainsPoint, nearestHitPoint }
    public let elementID: String?
    public let elementLabel: String?
    public let elementType: String?
    public let resolution: Resolution

    public init(
        elementID: String?,
        elementLabel: String?,
        elementType: String? = nil,
        resolution: Resolution
    ) {
        self.elementID = elementID
        self.elementLabel = elementLabel
        self.elementType = elementType
        self.resolution = resolution
    }
}

/// One recorded tool invocation inside a session. Arguments are already
/// redacted by the recorder — never store raw secrets here.
public struct SessionAction: Sendable, Codable, Equatable {
    /// Why an action was recorded. Only test steps and assertions normally become generated code;
    /// recording also captures the exploration needed to discover a stable flow.
    public enum Intent: String, Sendable, Codable {
        case testStep
        case assertion
        case diagnostic
        case recovery
        case failedProbe
    }

    public let timestamp: Date
    public let toolName: String
    public let arguments: [String: String]
    public let result: String
    public let isError: Bool
    public let intent: Intent
    public let observedElements: [RecordedElement]
    public let gestureTarget: RecordedGestureTarget?

    public init(
        timestamp: Date,
        toolName: String,
        arguments: [String: String],
        result: String,
        isError: Bool,
        intent: Intent = .testStep,
        observedElements: [RecordedElement] = [],
        gestureTarget: RecordedGestureTarget? = nil
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.intent = intent
        self.observedElements = observedElements
        self.gestureTarget = gestureTarget
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, toolName, arguments, result, isError, intent, observedElements, gestureTarget
    }

    /// Existing recordings predate intent classification. They preserve their former replayable
    /// behavior, while failed actions are still filtered by the compiler as a safety backstop.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        toolName = try container.decode(String.self, forKey: .toolName)
        arguments = try container.decode([String: String].self, forKey: .arguments)
        result = try container.decode(String.self, forKey: .result)
        isError = try container.decode(Bool.self, forKey: .isError)
        intent = try container.decodeIfPresent(Intent.self, forKey: .intent) ?? .testStep
        observedElements = try container.decodeIfPresent([RecordedElement].self, forKey: .observedElements) ?? []
        gestureTarget = try container.decodeIfPresent(RecordedGestureTarget.self, forKey: .gestureTarget)
    }

    public func recordingGestureTarget(_ target: RecordedGestureTarget) -> Self {
        Self(
            timestamp: timestamp,
            toolName: toolName,
            arguments: arguments,
            result: result,
            isError: isError,
            intent: intent,
            observedElements: observedElements,
            gestureTarget: target
        )
    }
}

public extension SessionAction {
    /// Applies the current session's secret set even to observations recorded before text entry.
    func redacted(using redactor: ArtifactRedactor) -> Self {
        Self(
            timestamp: timestamp, toolName: toolName,
            arguments: arguments.mapValues(redactor.redact), result: redactor.redact(result),
            isError: isError, intent: intent,
            observedElements: observedElements.map { element in
                RecordedElement(
                    id: element.id.map(redactor.redact), label: element.label.map(redactor.redact),
                    elementType: element.elementType, frame: element.frame, hitPoint: element.hitPoint
                )
            },
            gestureTarget: gestureTarget.map { target in
                RecordedGestureTarget(
                    elementID: target.elementID.map(redactor.redact),
                    elementLabel: target.elementLabel.map(redactor.redact),
                    elementType: target.elementType, resolution: target.resolution
                )
            }
        )
    }
}

// swiftlint:enable multiline_arguments
