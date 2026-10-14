import Foundation
import MobileDevices
import SwiftyShell

public protocol EmulatorRunning: Sendable {
    func launch(avdName: String, port: Int) async throws
    /// Like `launch`, but returns a handle to the process when one is available, so a boot wait can
    /// notice it died instead of sleeping out its whole timeout.
    func launchProcess(avdName: String, port: Int) async throws -> EmulatorInstance?
}

public extension EmulatorRunning {
    func launchProcess(avdName: String, port: Int) async throws -> EmulatorInstance? {
        try await launch(avdName: avdName, port: port)
        return nil
    }
}

public struct EmulatorRunner: EmulatorRunning {
    private let context: ShellContext

    /// Creates an emulator launcher with an injectable execution context.
    public init(context: ShellContext = .init()) {
        self.context = context
    }

    /// Launches an independent session and appends output to `$TMPDIR/amoo-emulator-<port>.log`.
    public func launch(avdName: String, port: Int) async throws {
        _ = try await launchProcess(avdName: avdName, port: port)
    }

    public func launchProcess(avdName: String, port: Int) async throws -> EmulatorInstance? {
        let log = NSTemporaryDirectory() + "amoo-emulator-\(port).log"
        // `.loadOnly` quick-boots from the snapshot but never saves one, so device state does not
        // accumulate between runs (`-no-snapshot-save`).
        return try await translatingMobileKitErrors {
            try await AndroidEmulatorManager(shell: context).start(
                avd: avdName, options: .init(snapshot: .loadOnly, port: port), logPath: log
            )
        }
    }
}
