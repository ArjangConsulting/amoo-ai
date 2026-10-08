// Validation deliberately checks each distinct public step shape before mutation.
// swiftlint:disable cyclomatic_complexity
import Foundation

public extension AccessibilityJourney {
    /// Reject misspelled/unknown expectations rather than silently weakening an authored check.
    static func decodeJSON(_ json: String) throws -> Self {
        guard json.utf8.count <= 131_072 else { throw AccessibilityJourneyValidationError() }
        let data = Data(json.utf8)
        let root = try JSONSerialization.jsonObject(with: data)
        let fields = try checkedObject(root, keys: ["schemaVersion", "id", "steps"])
        guard let steps = fields["steps"] as? [Any] else { throw AccessibilityJourneyValidationError() }
        for value in steps {
            let step = try checkedObject(value, keys: [
                "id", "kind", "element", "direction", "maxMoves", "speech", "action", "before", "after", "destination",
                "recoveryTimeoutMS"
            ])
            for key in ["element", "destination"] {
                if let value = step[key], !(value is NSNull) {
                    _ = try checkedObject(value, keys: ["id", "name", "role", "value", "enabled", "selected"])
                }
            }
            var speech = step["speech"] as? [Any] ?? []
            for key in ["before", "after"] {
                if let value = step[key], !(value is NSNull) {
                    speech.append(value)
                }
            }
            for value in speech {
                _ = try checkedObject(value, keys: ["elementID", "equals", "contains"])
            }
        }
        let journey = try JSONDecoder().decode(Self.self, from: data)
        try journey.validate()
        return journey
    }

    private static func checkedObject(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw AccessibilityJourneyValidationError()
        }
        return object
    }

    /// Validate all bounds before enabling VoiceOver or performing any app action.
    func validate() throws {
        guard schemaVersion == 1, Self.validID(id), (1 ... 20).contains(steps.count),
              Set(steps.map(\.id)).count == steps.count else { throw AccessibilityJourneyValidationError() }
        var moves = 0
        for step in steps {
            guard Self.validID(step.id) else { throw AccessibilityJourneyValidationError() }
            switch step.kind {
            case .element:
                guard let element = step.element, element.isValid,
                      step.direction == nil, step.maxMoves == nil, step.speech == nil,
                      step.action == nil, step.before == nil, step.after == nil, step.destination == nil,
                      step.recoveryTimeoutMS == nil
                else { throw AccessibilityJourneyValidationError() }
            case .seek, .order:
                guard step.element == nil, ["forward", "backward"].contains(step.direction ?? ""),
                      let speech = step.speech, !speech.isEmpty, speech.allSatisfy(\.isValid),
                      step.action == nil, step.before == nil, step.after == nil, step.destination == nil,
                      step.recoveryTimeoutMS == nil
                else { throw AccessibilityJourneyValidationError() }
                if step.kind == .seek {
                    guard speech.count == 1, let count = step.maxMoves, (1 ... 30).contains(count)
                    else { throw AccessibilityJourneyValidationError() }
                    moves += count
                } else {
                    guard step.maxMoves == nil else { throw AccessibilityJourneyValidationError() }
                    moves += speech.count
                }
            case .transition:
                guard let element = step.element, element.isValid,
                      let destination = step.destination, destination.isValid,
                      step.action != nil, step.before?.isValid == true, step.after?.isValid == true,
                      step.direction == nil, step.maxMoves == nil, step.speech == nil,
                      (0 ... 5000).contains(step.recoveryTimeoutMS ?? 2000)
                else { throw AccessibilityJourneyValidationError() }
            }
        }
        guard moves <= 30 else { throw AccessibilityJourneyValidationError() }
    }

    var requestedChecks: [String] {
        steps.flatMap { step in
            switch step.kind {
            case .element: step.element?.fields.map { "\(step.id).\($0.0)" } ?? []
            case .seek: ["\(step.id).seek"]
            case .order: (step.speech ?? []).indices.map { "\(step.id).order.\($0)" }
            case .transition:
                ["\(step.id).before", "\(step.id).action", "\(step.id).destination", "\(step.id).recovery"]
            }
        }
    }

    static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 256
    }
}

extension AccessibilityElementExpectation {
    var fields: [(String, String)] {
        var fields: [(String, String)] = []
        if let name {
            fields.append(("name", name))
        }
        if let role {
            fields.append(("role", role))
        }
        if let value {
            fields.append(("value", value))
        }
        if let enabled {
            fields.append(("enabled", String(enabled)))
        }
        if let selected {
            fields.append(("selected", String(selected)))
        }
        return fields
    }

    var isValid: Bool {
        AccessibilityJourney.validID(id) && !fields.isEmpty && fields.allSatisfy { $0.1.count <= 4096 }
            && (role == nil || !(role?.isEmpty ?? true))
    }
}

extension AccessibilitySpeechExpectation {
    var isValid: Bool {
        let terms = [equals, contains].compactMap(\.self)
        return terms.count == 1 && terms.allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4096
        } && (elementID == nil || AccessibilityJourney.validID(elementID ?? ""))
    }
}

public struct AccessibilityJourneyValidationError: Error, CustomStringConvertible {
    public var description: String {
        "Requires schemaVersion=1, unique named steps, explicit nonempty expectations,"
            + " 1...20 steps and at most 30 total moves. Each kind accepts only its documented fields."
    }
}

// swiftlint:enable cyclomatic_complexity
