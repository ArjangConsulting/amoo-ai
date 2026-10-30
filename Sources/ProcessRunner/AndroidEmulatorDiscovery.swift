import Foundation
import SwiftyShell

/// Host registration for one emulator, independent of guest Android and its ADB connection.
public struct AndroidEmulatorRegistration: Sendable, Equatable {
    public let pid: Int32
    public let serial: String
    public let avdID: String
    public let directory: URL

    public init(pid: Int32, serial: String, avdID: String, directory: URL) {
        self.pid = pid
        self.serial = serial
        self.avdID = avdID
        self.directory = directory
    }
}

/// Reads emulator discovery files without retaining their authentication fields, and falls back to
/// the process table because an emulator started without gRPC writes no discovery file at all.
public struct AndroidEmulatorDiscovery: Sendable {
    private let context: ShellContext
    private let directories: [URL]
    private let scansProcesses: Bool

    /// `scansProcesses` defaults to on only for the real discovery directories, so callers that
    /// inject directories get exactly the registrations those directories describe.
    public init(context: ShellContext = .init(), directories: [URL]? = nil, scansProcesses: Bool? = nil) {
        self.context = context
        self.directories = directories ?? Self.defaultDirectories()
        self.scansProcesses = scansProcesses ?? (directories == nil)
    }

    /// Registrations whose process still identifies the same AVD; stale and reused PIDs are excluded.
    public func runningEmulators() async throws -> [AndroidEmulatorRegistration] {
        var registrations: [AndroidEmulatorRegistration] = []
        var seen: Set<Int32> = []
        for directory in directories {
            let files = (
                try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            ) ??
                []
            for file in files where file.lastPathComponent.hasPrefix("pid_") && file.pathExtension == "ini" {
                guard let contents = try? String(contentsOf: file, encoding: .utf8),
                      let registration = Self.parse(contents, filename: file.lastPathComponent),
                      seen.insert(registration.pid).inserted,
                      try await isRunning(registration) else { continue }
                registrations.append(registration)
            }
        }
        if scansProcesses {
            for registration in try await processRegistrations() where seen.insert(registration.pid).inserted {
                registrations.append(registration)
            }
        }
        return registrations
    }

    /// Emulators amoo launches pass `-avd` and `-port` on the command line, which identifies the
    /// AVD and its ADB serial without a discovery file. Processes without `-port` are skipped
    /// because their serial cannot be derived.
    func processRegistrations() async throws -> [AndroidEmulatorRegistration] {
        let result = try await Command("ps").args(["-axo", "pid=,args="]).timeout(.seconds(3)).run(in: context)
        return result.stdout.split(whereSeparator: \.isNewline).compactMap { Self.parseProcess(String($0)) }
    }

    static func parseProcess(_ line: String) -> AndroidEmulatorRegistration? {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first, let pid = Int32(first), pid > 0,
              line.contains("qemu-system-"),
              let avdFlag = tokens.firstIndex(of: "-avd"), tokens.indices.contains(avdFlag + 1),
              let portFlag = tokens.firstIndex(of: "-port"), tokens.indices.contains(portFlag + 1),
              let port = Int(tokens[portFlag + 1]), (5554 ... 5682).contains(port), port.isMultiple(of: 2)
        else { return nil }
        let avd = tokens[avdFlag + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !avd.isEmpty else { return nil }
        return AndroidEmulatorRegistration(
            pid: pid,
            serial: "emulator-\(port)",
            avdID: avd,
            directory: avdDirectory(named: avd)
        )
    }

    /// Resolves an AVD's directory the way the emulator does: the AVD's `<name>.ini` points at it,
    /// otherwise it lives under the AVD home.
    static func avdDirectory(named avd: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? environment["ANDROID_USER_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("avd") }
            ?? home.appendingPathComponent(".android/avd")
        if let contents = try? String(contentsOf: root.appendingPathComponent("\(avd).ini"), encoding: .utf8),
           let line = contents.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("path=") }) {
            let path = line.dropFirst("path=".count).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path)
            }
        }
        return root.appendingPathComponent("\(avd).avd")
    }

    /// Verifies process identity instead of treating an emulator's acknowledgement as process exit.
    public func isRunning(_ registration: AndroidEmulatorRegistration) async throws -> Bool {
        do {
            let result = try await Command("ps").args(["-p", String(registration.pid), "-o", "args="])
                .timeout(.seconds(2)).run(in: context)
            let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = command.split(whereSeparator: \.isWhitespace)
            guard command.contains("qemu-system-") || tokens.first?.hasSuffix("/emulator") == true,
                  let flag = tokens.firstIndex(of: "-avd"), tokens.indices.contains(flag + 1) else { return false }
            return tokens[flag + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == registration.avdID
        } catch let error as ShellError {
            if case let .exitFailure(_, output) = error, output.exitCode == 1, output.stdout.isEmpty {
                return false
            }
            throw error
        }
    }

    static func parse(_ contents: String, filename: String) -> AndroidEmulatorRegistration? {
        let stem = String(filename.dropFirst(4)).replacingOccurrences(of: "_info.ini", with: "")
            .replacingOccurrences(of: ".ini", with: "")
        guard filename.hasPrefix("pid_"), let pid = Int32(stem), pid > 0 else { return nil }
        var fields: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if ["port.serial", "avd.id", "avd.dir"].contains(key) {
                fields[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let port = fields["port.serial"].flatMap(Int.init), (5554 ... 5682).contains(port),
              port.isMultiple(of: 2),
              let avdID = fields["avd.id"], !avdID.isEmpty,
              let path = fields["avd.dir"], path.hasPrefix("/") else { return nil }
        return AndroidEmulatorRegistration(
            pid: pid,
            serial: "emulator-\(port)",
            avdID: avdID,
            directory: URL(fileURLWithPath: path)
        )
    }

    static func defaultDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let owner = (try? FileManager.default.attributesOfItem(atPath: home.path)[.ownerAccountID]) as? NSNumber
        let roots = [
            environment["XDG_RUNTIME_DIR"], owner.map { "/run/user/\($0)" },
            home.appendingPathComponent("Library/Caches/TemporaryItems").path,
            NSTemporaryDirectory(), "/tmp/android-\(NSUserName())"
        ].compactMap(\.self)
        return roots.map { URL(fileURLWithPath: $0).appendingPathComponent("avd/running") }
    }
}
