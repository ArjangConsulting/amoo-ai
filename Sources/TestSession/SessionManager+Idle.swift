import Foundation

/// Ending sessions nobody is using, so a caller that stops without `end_session` cannot hold a
/// device and its companion for the life of the server.
public extension SessionManager {
    /// `AMOO_SESSION_IDLE_MINUTES` (default 30; 0 never ends an idle session).
    static func idleLimitFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Swift.Duration? {
        let minutes = environment["AMOO_SESSION_IDLE_MINUTES"].flatMap(Double.init) ?? 30
        return minutes > 0 ? .seconds(minutes * 60) : nil
    }

    /// True when the session was ended for inactivity, so the caller can be told why it is closed.
    func wasEndedForInactivity(_ id: String) -> Bool {
        idleEnded.contains(id)
    }

    /// Ends every active session idle past the limit. Returns the ended session IDs.
    @discardableResult
    func endIdleSessions(now: ContinuousClock.Instant = .now) async -> [String] {
        guard let idleLimit else { return [] }
        var ended: [String] = []
        for session in allSessions() where await session.isActive {
            let id = session.id
            guard let last = lastActivity[id], now - last >= idleLimit else { continue }
            // Marked before the await: a call racing the close must read the reason, not a bare "closed".
            idleEnded.insert(id)
            do {
                try await endSession(id)
                ended.append(id)
            } catch {
                idleEnded.remove(id)
            }
        }
        return ended
    }

    internal func startIdleReaperIfNeeded() {
        guard idleLimit != nil, idleReaper == nil else { return }
        let interval = idleCheckInterval
        idleReaper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.endIdleSessions()
            }
        }
    }
}
