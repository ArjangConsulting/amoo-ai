import AmooLogging
import Foundation
import MCPServer
import Synchronization
#if canImport(SwiftyChain)
import SwiftyChain
#endif

/// Saves a credential value where only amoo can read it back. Values never pass through a flag,
/// an environment variable or an agent.
protocol CredentialWriting: Sendable {
    /// Whether this host has a store; mock profiles work without one.
    var isAvailable: Bool { get }
    func save(_ value: String, service: String, account: String, label: String) async throws
}

private let logger = AmooLogger.forType(KeychainCredentialStore.self)

/// The user's macOS Keychain, through SwiftyChain. An item amoo saves trusts the amoo binary, so
/// reading it back does not prompt; a rebuilt binary has a new signature and macOS asks again.
/// A read never waits past `timeout` for that prompt: it reports the store as locked instead, so an
/// agent's call cannot hang on a dialog nobody is watching.
struct KeychainCredentialStore: SecretStore, CredentialWriting {
    var timeout: Duration = .seconds(10)

    var isAvailable: Bool {
        #if canImport(SwiftyChain)
        true
        #else
        false
        #endif
    }

    func load(service: String, account: String) async throws -> String {
        #if canImport(SwiftyChain)
        logger.info("Reading keychain credential", context: "action=load service=\(service)")
        let key = KeychainKey<String>(service: service, account: account)
        let value: String?
        do {
            value = try await withAbandonableTimeout(timeout) {
                try await Keychain().loadIfPresent(key: key)
            }
        } catch let error as SecretStoreError {
            logger.error("Keychain read timed out", error: error, context: "action=load service=\(service)")
            throw error
        } catch {
            logger.error("Keychain read failed", error: error, context: "action=load service=\(service)")
            throw SecretStoreError.locked
        }
        guard let value else { throw SecretStoreError.notFound }
        logger.info("Read keychain credential", context: "action=load service=\(service)")
        return value
        #else
        throw SecretStoreError.unavailable
        #endif
    }

    func save(_ value: String, service: String, account: String, label: String) async throws {
        #if canImport(SwiftyChain)
        logger.info("Saving keychain credential", context: "action=save service=\(service)")
        do {
            try await Keychain().upsert(
                value,
                for: KeychainKey<String>(service: service, account: account, label: label)
            )
        } catch {
            logger.error("Keychain save failed", error: error, context: "action=save service=\(service)")
            throw error
        }
        logger.info("Saved keychain credential", context: "action=save service=\(service)")
        #else
        throw SecretStoreError.unavailable
        #endif
    }
}

/// Runs `operation` and returns its result, or throws ``SecretStoreError/locked`` after `timeout`.
/// Unlike a task group, it does not wait for a timed-out operation: a keychain read blocked on a
/// macOS prompt cannot be cancelled, so it is left to finish (or not) on its own.
func withAbandonableTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let gate = ResumeOnce(continuation)
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            gate.resume(with: .failure(SecretStoreError.locked))
        }
        Task.detached {
            do {
                try await gate.resume(with: .success(operation()))
            } catch {
                gate.resume(with: .failure(error))
            }
            timer.cancel()
        }
    }
}

private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
    }
}
