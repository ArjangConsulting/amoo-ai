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
    shutdown: @Sendable () async -> Void,
    runnerExit: @escaping @Sendable () async -> Void = { await CompanionSignalWaiter.never() },
    maxRestarts: Int = 3,
    signals: CompanionSignalWaiter = CompanionSignalWaiter()
) async throws {
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

    // Hold until a signal, restarting a runner that dies underneath. Without this the holder kept
    // announcing "holding it open" over a dead port — a runner killed mid-session (or one XCTest
    // relaunched into running zero tests) looked alive until the next command failed.
    let (events, eventSink) = AsyncStream.makeStream(of: HoldEvent.self)
    Task {
        await signals.wait()
        eventSink.yield(.signal)
    }
    var iterator = events.makeAsyncIterator()
    var restarts = 0
    while true {
        let watcher = Task {
            await runnerExit()
            if !Task.isCancelled {
                eventSink.yield(.runnerExited)
            }
        }
        let event = await iterator.next() ?? .signal
        watcher.cancel()
        guard event == .runnerExited else { break }
        restarts += 1
        guard restarts <= maxRestarts else {
            await shutdown()
            throw CompanionHoldError.runnerKeepsExiting(restarts: maxRestarts)
        }
        print("Restarting the companion runner (\(restarts)/\(maxRestarts))...")
        do {
            try await start()
        } catch {
            await shutdown()
            throw error
        }
        announce()
    }
    await shutdown()
}

private enum HoldEvent: Sendable {
    case signal, runnerExited
}

enum CompanionHoldError: Error, CustomStringConvertible {
    case runnerKeepsExiting(restarts: Int)

    var description: String {
        switch self {
        case let .runnerKeepsExiting(restarts):
            "The companion runner exited again after \(restarts) restarts; see the launch log above."
        }
    }
}

/// Resolves every `wait()` — past or future — once SIGINT or SIGTERM arrives. Armed on creation.
final class CompanionSignalWaiter: @unchecked Sendable {
    /// Suspends until cancelled — the runner watch for a holder that owns no runner.
    static func never() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var sources: [DispatchSourceSignal] = []
    private var finished = false

    /// - Parameter signals: what ends the wait. Tests pass none and call ``finish()`` instead, so
    ///   the test process keeps its own SIGINT and SIGTERM handling.
    init(signals: [Int32] = [SIGINT, SIGTERM]) {
        #if os(macOS) || os(Linux)
        signals.forEach { signal($0, SIG_IGN) }
        let created = signals.map { signalNumber in
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

    func finish() {
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
