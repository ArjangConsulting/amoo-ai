import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

actor CLILoadingIndicator {
    private static let frames = ["|", "/", "-", "\\"]

    private let message: String
    private let isEnabled: Bool
    private var renderTask: Task<Void, Never>?
    private var hasRendered = false

    init(message: String, isEnabled: Bool = isatty(STDERR_FILENO) != 0) {
        self.message = message
        self.isEnabled = isEnabled
    }

    func start(after delay: Duration = .milliseconds(150)) {
        guard isEnabled, renderTask == nil else { return }

        hasRendered = false
        let message = message
        renderTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            self.markRendered()

            var index = 0
            while !Task.isCancelled {
                Self.writeToStandardError("\r[\(Self.frames[index])] \(message)")
                index = (index + 1) % Self.frames.count

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    break
                }
            }
        }
    }

    func stop() async {
        guard isEnabled else { return }

        renderTask?.cancel()
        _ = await renderTask?.result
        renderTask = nil

        guard hasRendered else { return }

        let blankLine = String(repeating: " ", count: message.utf8.count + 6)
        Self.writeToStandardError("\r\(blankLine)\r")
        hasRendered = false
    }

    private func markRendered() {
        hasRendered = true
    }

    nonisolated private static func writeToStandardError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

func withCLILoadingIndicator<T>(
    _ message: String,
    operation: () async throws -> T
) async throws -> T {
    let indicator = CLILoadingIndicator(message: message)
    await indicator.start()

    do {
        let value = try await operation()
        await indicator.stop()
        return value
    } catch {
        await indicator.stop()
        throw error
    }
}

func withCLILoadingIndicator<T>(
    _ message: String,
    operation: () async -> T
) async -> T {
    let indicator = CLILoadingIndicator(message: message)
    await indicator.start()

    let value = await operation()
    await indicator.stop()
    return value
}
