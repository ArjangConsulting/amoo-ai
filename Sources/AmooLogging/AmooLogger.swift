import Foundation
#if canImport(OSLog)
import OSLog
#else
import Logging
#endif

/// amoo's structured logger.
///
/// On Apple platforms it logs to the unified log, so nothing reaches the terminal; elsewhere it is
/// swift-log, whose default handler writes to stderr. The API mirrors SwiftCommons'
/// `Logger.forType(subsystem:_:)` and `error(_:error:context:)`. SwiftCommons itself is not used:
/// its `Logger` is OSLog-only (this package also builds on Linux), and its `StringParsable`
/// conformances make `Int.init` ambiguous in every module that loads it.
///
/// Messages and `context` must hold identifiers and non-sensitive state, never user data.
public struct AmooLogger: Sendable {
    #if canImport(OSLog)
    private let logger: Logger
    #else
    private let logger: Logging.Logger
    #endif

    /// A logger whose category is the name of `type`.
    public static func forType(subsystem: String = "amoo", _ type: Any.Type) -> Self {
        #if canImport(OSLog)
        Self(logger: Logger(subsystem: subsystem, category: String(describing: type)))
        #else
        Self(logger: Logging.Logger(label: "\(subsystem).\(String(describing: type))"))
        #endif
    }

    public func debug(_ message: String, context: String? = nil) {
        let line = Self.line(message, context)
        #if canImport(OSLog)
        logger.debug("\(line, privacy: .public)")
        #else
        logger.debug("\(line)")
        #endif
    }

    public func info(_ message: String, context: String? = nil) {
        let line = Self.line(message, context)
        #if canImport(OSLog)
        logger.info("\(line, privacy: .public)")
        #else
        logger.info("\(line)")
        #endif
    }

    /// An error without an underlying `Error`, such as a failed postcondition.
    public func error(_ message: String, context: String? = nil) {
        let line = Self.line(message, context)
        #if canImport(OSLog)
        logger.error("\(line, privacy: .public)")
        #else
        logger.error("\(line)")
        #endif
    }

    /// Logs the error's type publicly. Its description can embed user data such as file paths, so
    /// the unified log redacts it.
    public func error(_ message: String, error: any Error, context: String? = nil) {
        let line = Self.line(message, context)
        #if canImport(OSLog)
        let identity = String(reflecting: type(of: error))
        let reason = error.localizedDescription
        logger.error("\(line, privacy: .public) | Error: \(identity, privacy: .public) (\(reason, privacy: .private))")
        #else
        logger.error("\(line) | Error: \(error)")
        #endif
    }

    private static func line(_ message: String, _ context: String?) -> String {
        context.map { "\(message) | Context: \($0)" } ?? message
    }
}
