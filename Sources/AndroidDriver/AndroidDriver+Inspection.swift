import AmooCore
import CompanionProtocol
import Foundation
import ProcessRunner

public enum AndroidInspectionMode: String, Sendable, Equatable {
    case companion
    case androidCLI = "android-cli"
    case automatic
    case compare

    /// The companion is the authoritative production inspector: it preserves package scope,
    /// parent semantics, Compose click targets, and the complete accessibility tree. Set
    /// `AMOO_ANDROID_INSPECTION_MODE` to `companion`, `android-cli`, or `compare` to override it.
    public static func productionDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        environment["AMOO_ANDROID_INSPECTION_MODE"].flatMap(Self.init(rawValue:)) ?? .companion
    }
}

public struct AndroidInspectionComparison: Sendable, Equatable {
    public let companionElementCount: Int
    public let androidCLIElementCount: Int
    public let matchingIdentityCount: Int
    public let companionOnlyIdentityCount: Int
    public let androidCLIOnlyIdentityCount: Int

    public init(
        companionElementCount: Int,
        androidCLIElementCount: Int,
        matchingIdentityCount: Int,
        companionOnlyIdentityCount: Int = 0,
        androidCLIOnlyIdentityCount: Int = 0
    ) {
        self.companionElementCount = companionElementCount
        self.androidCLIElementCount = androidCLIElementCount
        self.matchingIdentityCount = matchingIdentityCount
        self.companionOnlyIdentityCount = companionOnlyIdentityCount
        self.androidCLIOnlyIdentityCount = androidCLIOnlyIdentityCount
    }
}

extension AndroidDriver {
    public func latestInspectionComparison() -> AndroidInspectionComparison? {
        inspectionComparison
    }

    func inspectHierarchy() async throws -> ViewNode {
        switch inspectionMode {
        case .companion:
            return try await companionHierarchy()
        case .androidCLI:
            return try await androidCLIHierarchy()
        case .automatic:
            return try await automaticHierarchy()
        case .compare:
            // Both backends inspect the same device accessibility state. Running them concurrently
            // can make UIAutomator return truncated JSON, so comparison deliberately samples them
            // sequentially while leaving the companion result authoritative.
            let companion = try await companionHierarchy()
            do {
                let cli = try await androidCLIHierarchy()
                recordComparison(companion: companion, androidCLI: cli)
            } catch {
                writeComparisonDiagnostic("AndroidCLI inspection failed: \(error)")
            }
            return companion
        }
    }

    func inspectElements(selector: ElementSelector) async throws -> [ElementInfo] {
        // AndroidCLI currently exposes a flat layout, so parent relationships and Amoo's
        // semantic-description matching cannot be reproduced without weakening query semantics.
        if selector.parentSelector != nil || selector.description != nil {
            return try await companion.findElements(selector)
        }
        switch inspectionMode {
        case .companion:
            return try await companion.findElements(selector)
        case .androidCLI:
            return try await androidCLIElements().filter { $0.matches(selector) }
        case .automatic:
            return try await automaticElements(selector: selector)
        case .compare:
            let companionElements = try await companion.findElements(selector)
            do {
                let cliElements = try await androidCLIElements().filter { $0.matches(selector) }
                recordComparison(companion: companionElements, androidCLI: cliElements)
            } catch {
                writeComparisonDiagnostic("AndroidCLI inspection failed: \(error)")
            }
            return companionElements
        }
    }

    private func companionHierarchy() async throws -> ViewNode {
        try await companion.getViewHierarchy(appID: nil, candidateBundleIDs: [])
    }

    private func automaticHierarchy() async throws -> ViewNode {
        // A non-empty AndroidCLI layout can still be truncated when it loses Android's single
        // UI-automation-owner race to the live companion. There is no reliable completeness bit,
        // so automatic mode must keep the companion authoritative and use CLI only as recovery.
        do {
            return try await companionHierarchy()
        } catch {
            writeComparisonDiagnostic("Companion hierarchy inspection failed: \(error); falling back to AndroidCLI")
            return try await androidCLIHierarchy()
        }
    }

    private func automaticElements(selector: ElementSelector) async throws -> [ElementInfo] {
        do {
            return try await companion.findElements(selector)
        } catch {
            writeComparisonDiagnostic("Companion element inspection failed: \(error); falling back to AndroidCLI")
            return try await androidCLIElements().filter { $0.matches(selector) }
        }
    }

    private func androidCLIHierarchy() async throws -> ViewNode {
        try await ViewNode(id: "android-cli-root", children: androidCLIElements().map(\.viewNode))
    }

    private func androidCLIElements() async throws -> [ElementInfo] {
        try await androidCLI.layout(device: activeSerial, diff: false).map(\.elementInfo)
    }

    private func recordComparison(companion: ViewNode, androidCLI: ViewNode) {
        recordComparison(companion: companion.flattenedElements, androidCLI: androidCLI.flattenedElements)
    }

    private func recordComparison(companion: [ElementInfo], androidCLI: [ElementInfo]) {
        let companionIDs = Set(companion.map(\.comparisonIdentity).filter { !$0.isEmpty })
        let cliIDs = Set(androidCLI.map(\.comparisonIdentity).filter { !$0.isEmpty })
        let matchingIDs = companionIDs.intersection(cliIDs)
        inspectionComparison = AndroidInspectionComparison(
            companionElementCount: companion.count,
            androidCLIElementCount: androidCLI.count,
            matchingIdentityCount: matchingIDs.count,
            companionOnlyIdentityCount: companionIDs.subtracting(cliIDs).count,
            androidCLIOnlyIdentityCount: cliIDs.subtracting(companionIDs).count
        )
        if let inspectionComparison {
            writeComparisonDiagnostic(
                "companion=\(inspectionComparison.companionElementCount) "
                    + "android-cli=\(inspectionComparison.androidCLIElementCount) "
                    + "matching=\(inspectionComparison.matchingIdentityCount) "
                    + "companion-only=\(inspectionComparison.companionOnlyIdentityCount) "
                    + "android-cli-only=\(inspectionComparison.androidCLIOnlyIdentityCount)"
            )
        }
    }

    private func writeComparisonDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("[amoo][android-inspection] \(message)\n".utf8))
    }
}

private extension AndroidLayoutSnapshotElement {
    var elementInfo: ElementInfo {
        let label = contentDescription ?? text ?? ""
        return ElementInfo(
            id: resourceID ?? "",
            label: label,
            value: text == label ? nil : text,
            type: inferredType,
            frame: bounds.flatMap(Rect.init(androidBounds:)) ?? center.flatMap(Rect.init(androidCenter:)),
            isEnabled: !state.contains("disabled"),
            isVisible: !isOffScreen
        )
    }

    private var inferredType: ElementType {
        if interactions.contains("scrollable") {
            return .scrollView
        }
        if interactions.contains("checkable") {
            return .switchControl
        }
        if interactions.contains("clickable") || interactions.contains("long-clickable") {
            return .button
        }
        if interactions
            .contains("password") || (interactions.contains("focusable") && text != nil) {
            return .textField
        }
        return text == nil ? .other : .staticText
    }
}

private extension Rect {
    init?(androidBounds: String) {
        let values = androidBounds.split(whereSeparator: { !($0.isNumber || $0 == "-" || $0 == ".") })
            .compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        self.init(x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
    }

    init?(androidCenter: String) {
        let values = androidCenter.split(whereSeparator: { !($0.isNumber || $0 == "-" || $0 == ".") })
            .compactMap { Double($0) }
        guard values.count == 2 else { return nil }
        self.init(x: values[0], y: values[1], width: 0, height: 0)
    }
}

private extension ElementInfo {
    func matches(_ selector: ElementSelector) -> Bool {
        if let id = selector.id, self.id != id {
            return false
        }
        if let label = selector.label, self.label != label {
            return false
        }
        if let text = selector.containsText {
            let haystack = [label, value ?? ""].joined(separator: " ").lowercased()
            if !haystack.contains(text.lowercased()) {
                return false
            }
        }
        if let description = selector.description {
            let haystack = [id, label, value ?? ""].joined(separator: " ").lowercased()
            if !haystack.contains(description.lowercased()) {
                return false
            }
        }
        if selector.labeledOnly, id.isEmpty, label.isEmpty {
            return false
        }
        return selector.parentSelector == nil
    }

    var comparisonIdentity: String {
        !id.isEmpty ? "id:\(id)" : (!label.isEmpty ? "label:\(label)" : "")
    }

    var viewNode: ViewNode {
        ViewNode(
            id: id,
            label: label,
            value: value,
            type: type,
            frame: frame,
            isEnabled: isEnabled,
            isVisible: isVisible
        )
    }
}

private extension ViewNode {
    var flattenedElements: [ElementInfo] {
        let current = ElementInfo(
            id: id,
            label: label,
            value: value,
            type: type,
            frame: frame,
            isEnabled: isEnabled,
            isVisible: isVisible
        )
        return [current] + children.flatMap(\.flattenedElements)
    }
}
