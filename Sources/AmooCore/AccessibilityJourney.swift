// SwiftFormat compact wrapping conflicts with SwiftLint argument layout.
// swiftlint:disable multiline_parameters
import Foundation

/// An app-authored, locale-specific journey. Assertions describe task expectations, not universal rules.
public struct AccessibilityJourney: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var steps: [AccessibilityJourneyStep]

    public init(id: String, steps: [AccessibilityJourneyStep], schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.steps = steps
    }
}

/// Each step is a named checkpoint; a transition preserves VoiceOver through the action and recovery check.
public struct AccessibilityJourneyStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case element, seek, order, transition }
    public enum Action: String, Codable, Sendable { case tap, doubleTap }

    public var id: String
    public var kind: Kind
    public var element: AccessibilityElementExpectation?
    public var direction: String?
    public var maxMoves: Int?
    public var speech: [AccessibilitySpeechExpectation]?
    public var action: Action?
    public var before: AccessibilitySpeechExpectation?
    public var after: AccessibilitySpeechExpectation?
    public var destination: AccessibilityElementExpectation?
    public var recoveryTimeoutMS: Int?

    public init(
        id: String, kind: Kind, element: AccessibilityElementExpectation? = nil,
        direction: String? = nil, maxMoves: Int? = nil, speech: [AccessibilitySpeechExpectation]? = nil,
        action: Action? = nil, before: AccessibilitySpeechExpectation? = nil,
        after: AccessibilitySpeechExpectation? = nil, destination: AccessibilityElementExpectation? = nil,
        recoveryTimeoutMS: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.element = element
        self.direction = direction
        self.maxMoves = maxMoves
        self.speech = speech
        self.action = action
        self.before = before
        self.after = after
        self.destination = destination
        self.recoveryTimeoutMS = recoveryTimeoutMS
    }
}

/// XCTest's computed type/name/state are asserted as exported metadata, never as a complete trait set.
public struct AccessibilityElementExpectation: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var role: String?
    public var value: String?
    public var enabled: Bool?
    public var selected: Bool?

    public init(
        id: String, name: String? = nil, role: String? = nil, value: String? = nil,
        enabled: Bool? = nil, selected: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.value = value
        self.enabled = enabled
        self.selected = selected
    }
}

/// Exactly one of equals/contains is required. An element ID is an author association, not observed focus identity.
public struct AccessibilitySpeechExpectation: Codable, Sendable, Equatable {
    public var elementID: String?
    public var equals: String?
    public var contains: String?

    public init(elementID: String? = nil, equals: String? = nil, contains: String? = nil) {
        self.elementID = elementID
        self.equals = equals
        self.contains = contains
    }

    public func matches(_ utterance: String) -> Bool {
        if let equals {
            return utterance == equals
        }
        if let contains {
            return utterance.contains(contains)
        }
        return false
    }

    public var description: String {
        equals.map { "equals: \($0)" } ?? "contains: \(contains ?? "")"
    }
}

/// Nullable properties preserve unavailable evidence instead of manufacturing false/empty state.
public struct AccessibilityElementEvidence: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var role: String?
    public var value: String?
    public var enabled: Bool?
    public var selected: Bool?

    public init(
        id: String, name: String? = nil, role: String? = nil, value: String? = nil,
        enabled: Bool? = nil, selected: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.value = value
        self.enabled = enabled
        self.selected = selected
    }
}

/// Deterministic outcomes retain their checkpoint, expected target and transition association.
public struct AccessibilityJourneyCheck: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case pass, fail, unsupported, notEvaluated, needsReview }
    public var id: String
    public var checkpointID: String
    public var elementID: String?
    public var transitionID: String?
    public var source: String
    public var outcome: Outcome
    public var expected: String
    public var actual: String?
    public var reason: String
}

/// Raw checkpoint evidence is retained separately from assertion conclusions.
public struct AccessibilityJourneyCheckpoint: Codable, Sendable, Equatable {
    public var id: String
    public var elements: [AccessibilityElementEvidence] = []
    public var utterances: [String] = []
    public var elementCaptures: [AccessibilityJourneyElementCapture]?
}

/// Explicit stages retain empty before/after captures as well as the target capture.
public struct AccessibilityJourneyElementCapture: Codable, Sendable, Equatable {
    public var stage: String
    public var elements: [AccessibilityElementEvidence]
}

public struct AccessibilityJourneyReport: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var id: String
    public var specification: AccessibilityJourney?
    public var checks: [AccessibilityJourneyCheck] = []
    public var checkpoints: [AccessibilityJourneyCheckpoint] = []
}

// swiftlint:enable multiline_parameters
