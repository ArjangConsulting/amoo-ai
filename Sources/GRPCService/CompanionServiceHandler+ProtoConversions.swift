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
        element.label = label
        return element
    }
}

extension ViewNode {
    var protoViewNode: Amoo_ViewNode {
        var node = Amoo_ViewNode()
        node.id = id
        node.label = label
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
            parentSelector: parent
        )
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
