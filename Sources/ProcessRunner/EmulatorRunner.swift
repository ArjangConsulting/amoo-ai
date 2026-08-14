import SwiftyShell

public protocol EmulatorRunning: Sendable {
    func launch(avdName: String, port: Int) async throws
}

public struct EmulatorRunner: EmulatorRunning {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    public func launch(avdName: String, port: Int) async throws {
        let process = try await Command("emulator")
            .args(["-avd", avdName, "-port", String(port), "-no-snapshot-save"])
            .stdout(.discard)
            .stderr(.discard)
            .spawn(in: context, teardown: .interruptThenTerminate)
        await EmulatorProcessRegistry.shared.register(process, serial: "emulator-\(port)")
    }
}

/// Holds a strong reference to every emulator this process launched.
///
/// Write-only on purpose — nothing reads it back. The emulator outlives the `launch(avdName:port:)`
/// call that started it, and dropping the last reference to its `SpawnedProcess` would let the
/// handle deinit while the emulator is still booting. Deleting this as dead code would take the
/// emulator with it.
private actor EmulatorProcessRegistry {
    static let shared = EmulatorProcessRegistry()

    private var processes: [String: any SpawnedProcess] = [:]

    func register(_ process: any SpawnedProcess, serial: String) {
        processes[serial] = process
    }
}
