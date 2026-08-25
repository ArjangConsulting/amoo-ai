#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ANSIColor: String, Sendable {
    case reset = "\u{001B}[0m"
    case bold = "\u{001B}[1m"
    case dim = "\u{001B}[2m"

    // Foreground
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"
    case gray = "\u{001B}[90m"

    // Bright foreground
    case brightRed = "\u{001B}[91m"
    case brightGreen = "\u{001B}[92m"
    case brightYellow = "\u{001B}[93m"
    case brightCyan = "\u{001B}[96m"
}

/// Whether stdout is a terminal (enables colors).
public let isColorEnabled: Bool = isatty(STDOUT_FILENO) != 0

public func colored(_ text: String, _ colors: ANSIColor...) -> String {
    guard isColorEnabled else { return text }
    let prefix = colors.map(\.rawValue).joined()
    return "\(prefix)\(text)\(ANSIColor.reset.rawValue)"
}
