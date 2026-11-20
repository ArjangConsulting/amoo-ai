import AmooCore
import AmooLogging
import Foundation

private let logger = AmooLogger.forType(CompanionBuildIdentity.self)

/// Which companion build a start used, so a report says what is on the device instead of only that a
/// build was "cached": where it came from, when it was built, from which commit, and whether it is
/// older than its sources. Android adds the APK digests that decide whether the device needs it.
struct CompanionBuildIdentity: Codable, Equatable {
    /// `local` (built in this checkout) or `prebuilt` (packaged).
    var source: String
    /// The `.xctestrun` (iOS) or test APK (Android) the start used.
    var path: String
    /// When that product was written, ISO 8601.
    var builtAt: String?
    /// The commit the build came from, with `-dirty` for uncommitted companion changes; nil when the
    /// build did not record one (`make companion-build`, or a distribution older than this field).
    var sourceCommit: String?
    /// Older than its sources: started anyway, see `docs/companion-startup.md`.
    var stale: Bool
    /// Android: SHA-256 of the test APK this start installs.
    var sha256: String?
    /// Android: SHA-256 of the test APK the device held before this start; nil when it held none.
    var installedSHA256: String?

    enum CodingKeys: String, CodingKey {
        case source, path, stale
        case builtAt = "built_at"
        case sourceCommit = "source_commit"
        case sha256
        case installedSHA256 = "installed_sha256"
    }

    /// Whether the device already held this exact build before the start.
    var alreadyInstalled: Bool? {
        guard let sha256 else { return nil }
        return installedSHA256 == sha256
    }

    /// One line for the human `env up` summary.
    var summary: String {
        var parts = ["\(source) build"]
        if let builtAt {
            parts.append("built \(builtAt)")
        }
        parts.append(sourceCommit.map { "from \(String($0.prefix(12)))" } ?? "source commit unknown")
        if stale {
            parts.append("older than its sources (run `amoo companion build`)")
        }
        return "Companion: " + parts.joined(separator: ", ")
    }

    static func timestamp(of path: String) -> String? {
        modificationDate(URL(fileURLWithPath: path)).map { $0.formatted(.iso8601) }
    }
}

/// The commit a companion build came from, recorded next to its products when amoo builds them, and
/// by `scripts/package-companions.sh` for prebuilt products.
enum CompanionSourceCommit {
    static let fileName = "source-commit"

    static func read(directory: String) -> String? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    /// Records the checkout's current commit for a build just made in `directory`. Best effort: a build
    /// outside a git checkout records nothing.
    static func record(companionDir: String, directory: String) {
        guard let commit = current(companionDir: companionDir) else { return }
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try (commit + "\n").write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(fileName), atomically: true, encoding: .utf8
            )
        } catch {
            logger.error("Could not record the companion source commit", error: error, context: "dir=\(directory)")
        }
    }

    /// `git rev-parse HEAD`, with `-dirty` when the companion directory has uncommitted changes.
    static func current(companionDir: String) -> String? {
        guard let head = git(["rev-parse", "HEAD"], in: companionDir), !head.isEmpty else { return nil }
        let dirty = git(["status", "--porcelain", "--", "."], in: companionDir).map { !$0.isEmpty } ?? false
        return head + (dirty ? "-dirty" : "")
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension CompanionStartPhases {
    /// Records the build identity beside the phases, for the `env up` that spawned this start.
    func recordIdentity(_ identity: CompanionBuildIdentity) {
        logger.info(
            "Companion build selected",
            context: "source=\(identity.source) stale=\(identity.stale) commit=\(identity.sourceCommit ?? "unknown")"
        )
        guard let path = identityPath else { return }
        do {
            try JSONEncoder().encode(identity).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            logger.error("Could not write the companion build identity", error: error, context: "path=\(path)")
        }
    }

    static func identityPath(phasesPath: String) -> String {
        phasesPath + ".build.json"
    }

    static func readIdentity(phasesPath: String) -> CompanionBuildIdentity? {
        guard let data = FileManager.default.contents(atPath: identityPath(phasesPath: phasesPath)) else { return nil }
        return try? JSONDecoder().decode(CompanionBuildIdentity.self, from: data)
    }
}
