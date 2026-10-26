import AmooCore
import CompanionProtocol
import Foundation
import GRPCCore
import Protos

// MARK: - Proto Conversions

extension CapabilityDescriptor {
    var protoCapabilityDescriptor: Amoo_CapabilityDescriptor {
        var descriptor = Amoo_CapabilityDescriptor()
        descriptor.key = key
        descriptor.tier = switch tier {
        case .required:
            .required
        case .optional:
            .optional
        }
        descriptor.supported = supported
        descriptor.reasonIfUnsupported = reasonIfUnsupported ?? ""
        return descriptor
    }
}

extension Amoo_Point {
    var corePoint: Point {
        Point(x: x, y: y)
    }
}

extension Amoo_Direction {
    var coreDirection: Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .unspecified, .UNRECOGNIZED: .down
        }
    }
}

extension ElementInfo {
    var protoElementInfo: Amoo_ElementInfo {
        var element = Amoo_ElementInfo()
        element.id = id
        if let semantics {
            element.semantics = semantics.protoSemantics
        }
        element.label = label
        element.value = value ?? ""
        element.type = type?.rawValue ?? ""
        element.isEnabled = isEnabled
        element.isVisible = isVisible
        if let isSelected {
            element.isSelected = isSelected
        }
        if let placeholder {
            element.placeholder = placeholder
        }
        element.isSecureTextEntry = isSecureTextEntry
        if let frame {
            var rect = Amoo_Rect()
            rect.x = frame.x
            rect.y = frame.y
            rect.width = frame.width
            rect.height = frame.height
            element.frame = rect
        }
        if let hitPoint {
            var point = Amoo_Point()
            point.x = hitPoint.x
            point.y = hitPoint.y
            element.hitPoint = point
        }
        return element
    }
}

extension ViewNode {
    var protoViewNode: Amoo_ViewNode {
        var node = Amoo_ViewNode()
        node.id = id
        if let semantics {
            node.semantics = semantics.protoSemantics
        }
        if let isSelected {
            node.isSelected = isSelected
        }
        node.label = label
        node.isSecureTextEntry = isSecureTextEntry
        if let value {
            node.value = value
        }
        if let type {
            node.type = type.rawValue
        }
        if let frame {
            var rect = Amoo_Rect()
            rect.x = frame.x
            rect.y = frame.y
            rect.width = frame.width
            rect.height = frame.height
            node.frame = rect
        }
        node.isEnabled = isEnabled
        node.isVisible = isVisible
        if let placeholder {
            node.placeholder = placeholder
        }
        node.children = children.map(\.protoViewNode)
        return node
    }
}

extension Amoo_ElementSelector {
    var coreSelector: ElementSelector {
        let parent: ParentSelector? = hasParentSelector ? .selector(parentSelector.coreSelector) : nil

        return ElementSelector(
            id: id.nonEmpty,
            label: label.nonEmpty,
            containsText: containsText.nonEmpty,
            description: description_p.nonEmpty,
            parentSelector: parent,
            labeledOnly: labeledOnly
        )
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

extension ElementSemantics {
    var protoSemantics: Amoo_ElementSemantics {
        var result = Amoo_ElementSemantics()
        result.reference = reference
        result.parentReference = parentReference
        result.hierarchyPath = hierarchyPath
        result.attributes = attributes
        if let isCheckable {
            result.isCheckable = isCheckable
        }
        if let isChecked {
            result.isChecked = isChecked
        }
        if let stateDescription {
            result.stateDescription = stateDescription
        }
        if let fullFrame {
            result.fullFrame = Self.rect(fullFrame)
        }
        if let visibleFrame {
            result.visibleFrame = Self.rect(visibleFrame)
        }
        return result
    }

    private static func rect(_ frame: Rect) -> Amoo_Rect {
        var result = Amoo_Rect()
        result.x = frame.x
        result.y = frame.y
        result.width = frame.width
        result.height = frame.height
        return result
    }
}
