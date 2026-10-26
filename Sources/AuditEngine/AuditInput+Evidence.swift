import AmooCore

extension AuditInput {
    func evidence(for element: ElementInfo, index: Int) -> AuditEvidence {
        var attributes = element.semantics?.attributes ?? [:]
        attributes["elementID"] = element.id
        attributes["label"] = element.label
        attributes["type"] = element.type?.rawValue ?? "unknown"
        attributes["coordinateUnit"] = geometryUnit
        attributes["captureReference"] = captureReference
        attributes["hierarchyPath"] = element.semantics?.hierarchyPath ?? "unavailable"
        if let frame = element.semantics?.fullFrame ?? element.frame {
            attributes["x"] = String(frame.x)
            attributes["y"] = String(frame.y)
            attributes["width"] = String(frame.width)
            attributes["height"] = String(frame.height)
        } else {
            attributes["boundsAvailability"] = "unavailable"
        }
        let reference = element.semantics?.reference
        return AuditEvidence(
            kind: .selector,
            summary: "type=\(element.type?.rawValue ?? "unknown")",
            sourceRef: reference.flatMap { $0.isEmpty ? nil : $0 } ?? "\(captureReference):element[\(index)]",
            attributes: attributes
        )
    }
}
