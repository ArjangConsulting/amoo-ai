// SwiftFormat compact wrapping conflicts with argument layout lint.
// swiftlint:disable multiline_arguments multiline_parameters
import AmooCore
@testable import CompanionProtocol
import Foundation
import TestCommons
import XCTest

/// Opt-in transport fault tests. The verifier owns the lease, app, journal path and subsequent cleanup.
/// These tests deliberately return before restoration is known; they never claim a cleanup pass.
final class VoiceOverRecoveryQualificationTests: XCTestCase {
    private struct Configuration: Sendable {
        let connection: CompanionConnection
        let appID: String
        let journal: VoiceOverRecoveryJournal
        let evidenceDirectory: URL
    }

    private func configuration() throws -> Configuration {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AMOO_VOICEOVER_FAULT_QUALIFICATION"] == "1" else {
            throw XCTSkip("Live recovery qualification requires an explicitly owned simulator lease.")
        }
        guard let port = environment["AMOO_VOICEOVER_FAULT_PORT"].flatMap(Int.init),
              (1 ... 65535).contains(port),
              let appID = environment["AMOO_VOICEOVER_FAULT_APP"], !appID.isEmpty,
              let path = environment["AMOO_VOICEOVER_FAULT_JOURNAL"], path.hasPrefix("/"),
              let evidence = environment["AMOO_VOICEOVER_FAULT_EVIDENCE"], evidence.hasPrefix("/"),
              environment["AMOO_LEASE"]?.isEmpty == false else {
            throw AmooError.commandFailed(
                command: "VoiceOver recovery qualification",
                output: "Requires AMOO_LEASE and explicit port, app, absolute journal and evidence paths"
            )
        }
        return Configuration(
            connection: .init(host: "127.0.0.1", port: port), appID: appID,
            journal: .init(url: URL(fileURLWithPath: path)),
            evidenceDirectory: URL(fileURLWithPath: evidence)
        )
    }

    func testClientDeadlineLeavesCleanupUnknown() async throws {
        let config = try configuration()
        let rpc = try LiveCompanionRPCClient(connection: config.connection, inspectionTimeout: .seconds(5))
        let client = GRPCCompanionClient(connection: config.connection, rpcClient: rpc)
        do {
            try await requireRecoveryCapability(client)
            try requireNoPendingCleanup(config)
            let started = Date()
            let inspection = Task {
                try await client.inspectVoiceOver(appID: config.appID, phases: [.init(steps: 30, direction: "forward")])
            }
            defer { inspection.cancel() }
            let checkpoint = try await checkpoint(config, since: started)
            let result = try await inspection.value
            assertUnknownCleanup(result)
            XCTAssertTrue(result.error?.lowercased().contains("deadline") == true, result.error ?? "No deadline error")
            try writeEvidence(result, checkpoint: checkpoint, config: config, fault: "deadline")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testClientCancellationLeavesCleanupUnknown() async throws {
        let config = try configuration()
        let rpc = try LiveCompanionRPCClient(connection: config.connection)
        let client = GRPCCompanionClient(connection: config.connection, rpcClient: rpc)
        do {
            try await requireRecoveryCapability(client)
            try requireNoPendingCleanup(config)
            let started = Date()
            let inspection = Task {
                try await client.inspectVoiceOver(appID: config.appID, phases: [.init(steps: 30, direction: "forward")])
            }
            defer { inspection.cancel() }
            let checkpoint = try await checkpoint(config, since: started)
            inspection.cancel()
            let result = try await inspection.value
            assertUnknownCleanup(result)
            try writeEvidence(result, checkpoint: checkpoint, config: config, fault: "cancellation")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func requireRecoveryCapability(_ client: GRPCCompanionClient) async throws {
        let capabilities = try await client.getCapabilities()
        let supported = Set(capabilities.filter(\.supported).map(\.key))
        guard supported.isSuperset(of: ["accessibility.voiceOverPhases", "accessibility.voiceOverRecovery"]) else {
            throw AmooError.commandFailed(
                command: "fault qualification",
                output: "Durable VoiceOver recovery is required"
            )
        }
    }

    private func requireNoPendingCleanup(_ config: Configuration) throws {
        guard try config.journal.load() == nil else {
            throw AmooError.commandFailed(
                command: "fault qualification",
                output: "Resolve pending cleanup before another fault"
            )
        }
    }

    private func checkpoint(_ config: Configuration, since started: Date) async throws -> VoiceOverRecoveryJournal
        .Record {
        let record = try await waitUntil(
            timeout: .seconds(15), pollInterval: .milliseconds(20),
            operation: { try config.journal.load() },
            matching: {
                $0.map { $0.appID == config.appID && $0.startedAt >= started && $0.completedMoves >= 1 } ?? false
            }
        )
        return try XCTUnwrap(record)
    }

    private func assertUnknownCleanup(_ result: AccessibilityInspection) {
        XCTAssertEqual(result.executionStatus, "failed")
        XCTAssertEqual(result.verdict, "notAssessed")
        XCTAssertEqual(result.cleanupStatus, "unknown")
        XCTAssertNil(result.originalVoiceOverEnabled)
        XCTAssertNil(result.restoredVoiceOverEnabled)
        XCTAssertTrue(result.evaluatedChecks.isEmpty)
        XCTAssertFalse(result.notEvaluatedReasons.isEmpty)
    }

    private func writeEvidence(
        _ result: AccessibilityInspection, checkpoint: VoiceOverRecoveryJournal.Record,
        config: Configuration, fault: String
    ) throws {
        struct Evidence: Encodable {
            let fault: String
            let checkpoint: VoiceOverRecoveryJournal.Record
            let inspection: AccessibilityInspection
        }
        try FileManager.default.createDirectory(
            at: config.evidenceDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Evidence(fault: fault, checkpoint: checkpoint, inspection: result))
            .write(to: config.evidenceDirectory.appending(path: "\(fault)-transport.json"), options: .atomic)
    }
}

// swiftlint:enable multiline_arguments multiline_parameters
