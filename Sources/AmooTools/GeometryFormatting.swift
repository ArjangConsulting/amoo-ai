import AmooCore
import Foundation

/// Device-supplied geometry must never trap the host while formatting a diagnostic.
func geometryNumber(_ value: Double) -> String {
    guard value.isFinite, value > Double(Int.min), value < Double(Int.max) else { return "invalid" }
    return String(Int(value))
}

func validateGeometry(_ elements: [ElementInfo]) throws -> [ElementInfo] {
    for element in elements {
        var values: [Double] = []
        if let frame = element.frame {
            values += [frame.x, frame.y, frame.width, frame.height]
        }
        if let point = element.hitPoint {
            values += [point.x, point.y]
        }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000_000 }) else {
            throw ToolExecutionError(code: "invalid_geometry", message: "The device returned invalid element geometry.")
        }
    }
    return elements
}
