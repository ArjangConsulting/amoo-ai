import SwiftyShell

/// Typed process-layer boundary for Android Virtual Device creation.
/// StudioProtocol depends on this abstraction and never launches Android SDK tools directly.
public protocol AndroidVirtualDeviceCreating: Sendable {
    func create(name: String, systemImage: String, deviceType: String) async throws
}

public struct AndroidVirtualDeviceRunner: AndroidVirtualDeviceCreating {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    public func create(name: String, systemImage: String, deviceType: String) async throws {
        do {
            let command = Command("avdmanager")
                .args([
                    "create", "avd", "--force",
                    "--name", name,
                    "--package", systemImage,
                    "--device", deviceType
                ])
            _ = try await Command("printf").args(["no\n"]).pipe(to: command).run(in: context)
        } catch let error as ShellError {
            if case let .exitFailure(_, output) = error {
                throw ProcessRunnerError.nonZeroExit(
                    command: "avdmanager create avd",
                    exitCode: output.exitCode,
                    stderr: output.stderr
                )
            }
            throw error
        }
    }
}
