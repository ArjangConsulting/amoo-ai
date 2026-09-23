#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

// MARK: - Foreground lifecycle

/// Starts a companion and holds it until SIGINT or SIGTERM, tearing it down on every exit path.
///
/// The handlers are armed before the start, not after it. The runner is a child `xcodebuild`, and
/// a signal that arrived during the start — a caller giving up on a slow build or readiness probe
/// — used to hit the default handler, killing this process and orphaning the runner, which kept
/// serving the old build on the port. A failed start leaked it the same way.
func holdCompanion(
    start: @escaping @Sendable () async throws -> Void,
    announce: () -> Void,
    shutdown: @Sendable () async -> Void
) async throws {
    let signals = CompanionSignalWaiter()
    let starting = Task { try await start() }
    let interrupter = Task {
        await signals.wait()
        starting.cancel()
    }
    defer { interrupter.cancel() }

    do {
        try await starting.value
    } catch {
        await shutdown()
        throw error
    }
    announce()
    await signals.wait()
    await shutdown()
}

/// Resolves every `wait()` — past or future — once SIGINT or SIGTERM arrives. Armed on creation.
final class CompanionSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var sources: [DispatchSourceSignal] = []
    private var finished = false

    init() {
        #if os(macOS) || os(Linux)
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let created = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in self?.finish() }
            source.resume()
            return source
        }
        // A signal can arrive between `resume()` and this assignment, so `finish()` may already
        // have run. Cancel here instead of storing sources that nothing will ever tear down.
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished {
            sources = created
        }
        lock.unlock()
        if alreadyFinished {
            created.forEach { $0.cancel() }
        }
        #else
        finished = true
        #endif
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let pending = continuations
        continuations = []
        let activeSources = sources
        sources = []
        lock.unlock()

        activeSources.forEach { $0.cancel() }
        pending.forEach { $0.resume() }
    }
}
