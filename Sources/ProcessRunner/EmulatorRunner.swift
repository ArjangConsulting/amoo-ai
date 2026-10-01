import AmooCore
import Foundation
import SwiftyShell

public protocol EmulatorRunning: Sendable {
    func launch(avdName: String, port: Int) async throws
}

public struct EmulatorRunner: EmulatorRunning {
    private let context: ShellContext

    /// Creates an emulator launcher with an injectable execution context.
    public init(context: ShellContext = .init()) {
        self.context = context
    }

    /// Launches an independent session and appends output to `$TMPDIR/amoo-emulator-<port>.log`.
    public func launch(avdName: String, port: Int) async throws {
        try await DetachedProcess.spawn(
            Self.launchArguments(avdName: avdName, port: port),
            logPath: NSTemporaryDirectory() + "amoo-emulator-\(port).log",
            context: context
        )
    }

    public static func launchArguments(avdName: String, port: Int) -> [String] {
        ["emulator", "-avd", avdName, "-port", String(port), "-no-snapshot-save"]
    }
}
