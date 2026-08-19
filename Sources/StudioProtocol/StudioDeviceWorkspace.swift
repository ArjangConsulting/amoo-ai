import Foundation
import ProcessRunner

public enum StudioPlatform: String, Codable, Sendable { case ios = "Ios"; case android = "Android" }
public enum StudioDeviceStatus: String, Codable, Sendable { case running = "Running"; case available = "Available" }

public struct StudioDevice: Codable, Equatable, Sendable {
    public let id: String; public let name: String; public let platform: StudioPlatform
    public let osVersion: String; public let status: StudioDeviceStatus; public let physical: Bool
    public init(id: String, name: String, platform: StudioPlatform, osVersion: String, status: StudioDeviceStatus, physical: Bool) {
        self.id = id; self.name = name; self.platform = platform; self.osVersion = osVersion; self.status = status; self.physical = physical
    }
}
public struct StudioDeviceList: Codable, Sendable { public let devices: [StudioDevice] }
public struct StudioOperationResult: Codable, Equatable, Sendable {
    public let message: String; public let artifactPath: String?
    public init(message: String, artifactPath: String?) { self.message = message; self.artifactPath = artifactPath }
}
public struct StudioAppRequest: Sendable {
    public let deviceId: String; public let platform: String?; public let projectPath: String?
    public let appId: String; public let schemeOrModule: String?; public let artifactPath: String?
}
public enum StudioWorkspaceError: Error, CustomStringConvertible {
    case invalidParameter(String), command(String), artifactNotFound(String), unsupported(String)
    public var description: String { switch self {
    case let .invalidParameter(v): "Missing or invalid parameter: \(v)"
    case let .command(v), let .artifactNotFound(v), let .unsupported(v): v
    } }
}

public protocol StudioDeviceWorkspace: Sendable {
    func listDevices() async -> [StudioDevice]
    func startDevice(_ id: String) async -> StudioOperationResult
    func buildInstallRun(_ request: StudioAppRequest) async -> StudioOperationResult
    func reinstallRun(_ request: StudioAppRequest) async -> StudioOperationResult
    func resetData(_ request: StudioAppRequest) async -> StudioOperationResult
}

public struct LiveStudioDeviceWorkspace: StudioDeviceWorkspace {
    private let runner: any ProcessRunner
    public init(runner: any ProcessRunner = SystemProcessRunner()) { self.runner = runner }

    public func listDevices() async -> [StudioDevice] {
        async let ios = listIOS(); async let android = listAndroid()
        return await (ios + android).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func startDevice(_ id: String) async -> StudioOperationResult {
        let all = await listDevices()
        guard let device = all.first(where: { $0.id == id }) else { return .init(message: "Device is no longer available", artifactPath: nil) }
        do {
            if device.platform == .ios {
                try await checked(["xcrun", "simctl", "boot", id])
                _ = try? await runner.run(["open", "-a", "Simulator"])
            } else {
                try launchDetached(["emulator", "-avd", id])
            }
            return .init(message: "Started \(device.name)", artifactPath: nil)
        } catch { return .init(message: "Could not start \(device.name): \(error)", artifactPath: nil) }
    }

    public func buildInstallRun(_ request: StudioAppRequest) async -> StudioOperationResult {
        do {
            let platform = request.platform == "android" ? StudioPlatform.android : .ios
            let artifact = try await build(request, platform: platform)
            try await installAndRun(request, artifact: artifact, platform: platform)
            return .init(message: "Built, installed, and launched \(request.appId)", artifactPath: artifact)
        } catch { return .init(message: "Build/install failed: \(error)", artifactPath: nil) }
    }

    public func reinstallRun(_ request: StudioAppRequest) async -> StudioOperationResult {
        do {
            let artifact = try require(request.artifactPath, "artifactPath")
            let platform: StudioPlatform = artifact.hasSuffix(".apk") ? .android : .ios
            try await installAndRun(request, artifact: artifact, platform: platform)
            return .init(message: "Reinstalled and launched \(request.appId)", artifactPath: artifact)
        } catch { return .init(message: "Reinstall failed: \(error)", artifactPath: request.artifactPath) }
    }

    public func resetData(_ request: StudioAppRequest) async -> StudioOperationResult {
        do {
            if request.deviceId.hasPrefix("emulator-") || request.artifactPath?.hasSuffix(".apk") == true {
                try await checked(["adb", "-s", request.deviceId, "shell", "pm", "clear", request.appId])
            } else {
                try await checked(["xcrun", "simctl", "uninstall", request.deviceId, request.appId])
                if let artifact = request.artifactPath {
                    try await checked(["xcrun", "simctl", "install", request.deviceId, artifact])
                }
            }
            return .init(message: "Erased app data for \(request.appId)", artifactPath: request.artifactPath)
        } catch { return .init(message: "Could not erase app data: \(error)", artifactPath: request.artifactPath) }
    }

    private func listIOS() async -> [StudioDevice] {
        guard let result = try? await runner.run(["xcrun", "simctl", "list", "devices", "available", "--json"]),
              let data = result.stdout.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        return runtimes.flatMap { runtime, values -> [StudioDevice] in
            guard runtime.contains("iOS") else { return [] }
            let version = runtime.components(separatedBy: "iOS-").last?.replacingOccurrences(of: "-", with: ".") ?? ""
            return values.compactMap { value in
                guard let id = value["udid"] as? String, let name = value["name"] as? String else { return nil }
                return StudioDevice(id: id, name: name, platform: .ios, osVersion: version, status: (value["state"] as? String) == "Booted" ? .running : .available, physical: false)
            }
        }
    }

    private func listAndroid() async -> [StudioDevice] {
        let online = (try? await runner.run(["adb", "devices", "-l"]).stdout) ?? ""
        var devices = online.split(separator: "\n").compactMap { line -> StudioDevice? in
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count > 1, parts[1] == "device" else { return nil }
            let id = parts[0]; let model = parts.first { $0.hasPrefix("model:") }?.dropFirst(6).replacingOccurrences(of: "_", with: " ") ?? id
            return StudioDevice(id: id, name: model, platform: .android, osVersion: "", status: .running, physical: !id.hasPrefix("emulator-"))
        }
        let avds = (try? await runner.run(["emulator", "-list-avds"]).stdout) ?? ""
        let runningNames = Set(devices.map(\.name))
        devices += avds.split(separator: "\n").map(String.init).filter { !runningNames.contains($0) }.map {
            StudioDevice(id: $0, name: $0, platform: .android, osVersion: "", status: .available, physical: false)
        }
        return devices
    }

    private func build(_ request: StudioAppRequest, platform: StudioPlatform) async throws -> String {
        let path = try require(request.projectPath, "projectPath"); let target = request.schemeOrModule ?? ""
        if platform == .ios {
            let derived = FileManager.default.temporaryDirectory.appendingPathComponent("amoo-derived-\(UUID().uuidString)").path
            var args = ["xcodebuild"]
            if path.hasSuffix(".xcworkspace") { args += ["-workspace", path] } else if path.hasSuffix(".xcodeproj") { args += ["-project", path] } else { throw StudioWorkspaceError.unsupported("Choose an .xcodeproj or .xcworkspace") }
            args += ["-scheme", try require(target, "schemeOrModule"), "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=\(request.deviceId)", "-derivedDataPath", derived, "build"]
            try await checked(args)
            return try newestArtifact(in: derived, suffix: ".app")
        }
        let root = URL(fileURLWithPath: path).hasDirectoryPath ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
        let module = target.isEmpty ? "app" : target
        try await checked([root + "/gradlew", "--project-dir", root, ":\(module):assembleDebug"])
        return try newestArtifact(in: root + "/\(module)/build/outputs/apk", suffix: ".apk")
    }

    private func installAndRun(_ request: StudioAppRequest, artifact: String, platform: StudioPlatform) async throws {
        if platform == .ios {
            try await checked(["xcrun", "simctl", "install", request.deviceId, artifact]); try await checked(["xcrun", "simctl", "launch", request.deviceId, request.appId])
        } else {
            try await checked(["adb", "-s", request.deviceId, "install", "-r", artifact]); try await checked(["adb", "-s", request.deviceId, "shell", "monkey", "-p", request.appId, "1"])
        }
    }
    private func checked(_ args: [String]) async throws { let result = try await runner.run(args); guard result.exitCode == 0 else { throw StudioWorkspaceError.command(result.stderr.isEmpty ? result.stdout : result.stderr) } }
    private func require(_ value: String?, _ name: String) throws -> String { guard let value, !value.isEmpty else { throw StudioWorkspaceError.invalidParameter(name) }; return value }
    private func newestArtifact(in root: String, suffix: String) throws -> String {
        let url = URL(fileURLWithPath: root); guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { throw StudioWorkspaceError.artifactNotFound("No build output at \(root)") }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.path.hasSuffix(suffix) }
        guard let result = files.max(by: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }) else { throw StudioWorkspaceError.artifactNotFound("No \(suffix) artifact found") }
        return result.path
    }
    private func launchDetached(_ args: [String]) throws { let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = args; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run() }
}
