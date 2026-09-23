/// A hardware-keyboard key, as sent by `press_key`.
///
/// Named keys cover what a touch gesture cannot reach — arrows, Return, Escape, Tab — for testing
/// keyboard navigation. Anything else is a single character.
public enum KeyboardKey: Sendable, Equatable {
    case leftArrow, rightArrow, upArrow, downArrow
    case returnKey, escape, tab, space, delete
    case home, end, pageUp, pageDown
    case character(Character)

    /// The wire and tool name: `left_arrow`, `return`, …, or the character itself.
    public var name: String {
        switch self {
        case .leftArrow: "left_arrow"
        case .rightArrow: "right_arrow"
        case .upArrow: "up_arrow"
        case .downArrow: "down_arrow"
        case .returnKey: "return"
        case .escape: "escape"
        case .tab: "tab"
        case .space: "space"
        case .delete: "delete"
        case .home: "home"
        case .end: "end"
        case .pageUp: "page_up"
        case .pageDown: "page_down"
        case let .character(character): String(character)
        }
    }

    public static let namedKeys: [Self] = [
        .leftArrow, .rightArrow, .upArrow, .downArrow, .returnKey, .escape, .tab, .space, .delete,
        .home, .end, .pageUp, .pageDown
    ]

    /// Parses a named key or a single character; `nil` for anything else.
    public init?(name: String) {
        if let named = Self.namedKeys.first(where: { $0.name == name.lowercased() }) {
            self = named
        } else if name.count == 1, let character = name.first {
            self = .character(character)
        } else {
            return nil
        }
    }
}

/// A modifier held while a key is pressed.
public enum KeyModifier: String, Sendable, Equatable, CaseIterable, Comparable {
    case command, shift, option, control

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }
}
