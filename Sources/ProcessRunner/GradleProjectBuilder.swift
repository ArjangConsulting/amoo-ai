import GradleKit
import SwiftyShell

/// Builds Android project artifacts through ShipItSwifty's typed GradleKit API.
public protocol GradleProjectBuilding: Sendable {
    func assembleDebug(projectDirectory: String, module: String) async throws
}

public struct GradleProjectBuilder: GradleProjectBuilding {
    private let context: ShellContext

    public init(context: ShellContext = .init()) {
        self.context = context
    }

    public func assembleDebug(projectDirectory: String, module: String) async throws {
        do {
            _ = try await Gradle(context: context)
                .projectDir(projectDirectory)
                .task(GradleTask.assembleDebug.qualified(module: module))
                .flag(.noDaemon)
                .run()
        } catch let error as ShellError {
            let command = "gradlew \(GradleTask.assembleDebug.qualified(module: module).name)"
            if case let .exitFailure(_, output) = error {
                throw ProcessRunnerError.nonZeroExit(
                    command: command, exitCode: output.exitCode, stderr: output.stderr
                )
            }
            throw error
        }
    }
}
