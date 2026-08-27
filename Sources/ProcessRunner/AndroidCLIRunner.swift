import AndroidCLIKit
import Foundation
import SwiftyShell

/// Agent-friendly Android inspection backed by Google's Android CLI.
///
/// This is additive to ``ADBRunning``: ADB remains responsible for lifecycle operations that
/// Android CLI does not expose, while this boundary owns structured layout and visual targeting.
public protocol AndroidCLIRunning: Sendable {
    func version() async throws -> String
    func layout(device: String?, diff: Bool) async throws -> [AndroidLayoutSnapshotElement]
    func captureScreen(device: String?, output: String, annotated: Bool) async throws
    func resolveScreen(screenshot: String, instruction: String) async throws -> String
}

public struct AndroidLayoutSnapshotElement: Sendable, Equatable {
    public let text: String?
    public let resourceID: String?
    public let contentDescription: String?
    public let interactions: [String]
    public let state: [String]
    public let bounds: String?
    public let center: String?
    public let isOffScreen: Bool

    public init(
        text: String? = nil,
        resourceID: String? = nil,
        contentDescription: String? = nil,
        interactions: [String] = [],
        state: [String] = [],
        bounds: String? = nil,
        center: String? = nil,
        isOffScreen: Bool = false
    ) {
        self.text = text
        self.resourceID = resourceID
        self.contentDescription = contentDescription
        self.interactions = interactions
        self.state = state
        self.bounds = bounds
        self.center = center
        self.isOffScreen = isOffScreen
    }
}

public struct AndroidCLIRunner: AndroidCLIRunning {
    private let context: ShellContext
    private let executablePath: String
    private let sdkPath: String?

    public init(
        context: ShellContext = .init(),
        executablePath: String = "android",
        sdkPath: String? = nil
    ) {
        self.context = context
        self.executablePath = executablePath
        self.sdkPath = sdkPath
    }

    public func version() async throws -> String {
        try await run(command.version()).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func layout(device: String? = nil, diff: Bool = false) async throws -> [AndroidLayoutSnapshotElement] {
        let output = try await run(command.layout(device: device, diff: diff)).stdout
        // AndroidCLI 1.0 currently emits kebab-case keys, while AndroidCLIKit 0.6.0's model
        // decodes the earlier camelCase spelling. Normalize both known spellings here so IDs and
        // descriptions are not silently discarded; remove this shim once the upstream parser
        // accepts both forms.
        let normalizedOutput = output
            .replacingOccurrences(of: "\"resource-id\"", with: "\"resourceId\"")
            .replacingOccurrences(of: "\"content-desc\"", with: "\"contentDesc\"")
        return try AndroidCLIOutputParser.layoutElements(from: normalizedOutput).map {
            AndroidLayoutSnapshotElement(
                text: $0.text,
                resourceID: $0.resourceId,
                contentDescription: $0.contentDesc,
                interactions: $0.interactions ?? [],
                state: $0.state ?? [],
                bounds: $0.bounds,
                center: $0.center,
                isOffScreen: $0.offScreen ?? false
            )
        }
    }

    public func captureScreen(
        device: String? = nil,
        output: String,
        annotated: Bool = false
    ) async throws {
        _ = try await run(command.screenCapture(device: device, output: output, annotate: annotated))
    }

    public func resolveScreen(screenshot: String, instruction: String) async throws -> String {
        try await run(command.screenResolve(screenshot: screenshot, string: instruction))
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var command: AndroidCLI {
        AndroidCLI(context: context, executablePath: executablePath, sdkPath: sdkPath)
    }

    private func run(_ command: AndroidCLI) async throws -> ProcessResult {
        do {
            return try await command.run().processResult
        } catch let error as ShellError {
            if case let .exitFailure(_, output) = error {
                throw ProcessRunnerError.nonZeroExit(
                    command: command.command().displayString(),
                    exitCode: output.exitCode,
                    stderr: output.stderr
                )
            }
            throw error
        }
    }
}
