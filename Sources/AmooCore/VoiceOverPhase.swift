import Foundation

/// One direction in a continuous traversal. The whole request is limited to 30 moves and six phases.
public struct VoiceOverPhase: Codable, Sendable, Equatable {
    public var steps: Int
    public var direction: String

    public init(steps: Int, direction: String) {
        self.steps = steps
        self.direction = direction
    }

    public static func validate(_ phases: [Self]) throws {
        guard (1 ... 6).contains(phases.count),
              phases.allSatisfy({ (1 ... 30).contains($0.steps) && ["forward", "backward"].contains($0.direction) }),
              phases.reduce(0, { $0 + $1.steps }) <= 30 else {
            throw VoiceOverPhaseValidationError()
        }
    }
}

/// Phase boundaries retain direction, requested counts and any partial speech before an error.
public struct VoiceOverPhaseObservation: Codable, Sendable, Equatable {
    public var phaseIndex: Int
    public var direction: String
    public var requestedSteps: Int
    public var utterances: [String]

    public init(phaseIndex: Int, direction: String, requestedSteps: Int, utterances: [String]) {
        self.phaseIndex = phaseIndex
        self.direction = direction
        self.requestedSteps = requestedSteps
        self.utterances = utterances
    }
}

/// Invalid phase requests are rejected before any assistive-technology mutation.
public struct VoiceOverPhaseValidationError: Error, CustomStringConvertible {
    public var description: String {
        "Requires 1...6 forward/backward phases, each 1...30 steps, with at most 30 total moves"
    }
}
