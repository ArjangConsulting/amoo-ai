import AmooCore
import Foundation

extension DriverToolExecutor {
    func inspectionProvenance(
        _ incoming: AccessibilityInspection,
        driver: any PlatformDriver,
        arguments: [String: String],
        appID: String
    ) async throws -> AccessibilityInspection {
        var report = incoming
        report.provenance["app_id"] = appID
        report.provenance["host_binary"] = AmooBuildInfo.current.executablePath
        report.provenance["host_version"] = AmooBuildInfo.current.version
        report.provenance["host_commit"] = AmooBuildInfo.current.sourceCommit
        report.provenance["host_sha256"] = AmooBuildInfo.current.binarySHA256
        report.provenance["host_source_fingerprint"] = AmooBuildInfo.current.sourceFingerprint
        report.provenance["host_source_dirty"] = AmooBuildInfo.current.sourceDirty
        if let id = arguments["session_id"], let session = await sessionManager?.session(id) {
            if let hash = session.appArtifactSHA256 {
                report.provenance["app_build"] = hash
                report.provenance["app_build_source"] = "session-installed artifact SHA-256"
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let configuration = try encoder.encode([
                "arguments": session.launchArguments,
                "environment": session.launchEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            ])
            report.provenance["launch_configuration_sha256"] = sha256Hex(configuration)
            report.provenance["launch_locale"] = session.launchEnvironment["LANG"]
            if let index = session.launchArguments.firstIndex(of: "-AppleLanguages"),
               session.launchArguments.indices.contains(index + 1) {
                report.provenance["launch_ui_languages"] = session.launchArguments[index + 1]
            }
        }
        if let id = arguments["session_id"], let session = await sessionManager?.session(id),
           let index = session.launchArguments.firstIndex(of: "-AppleLocale"),
           session.launchArguments.indices.contains(index + 1) {
            report.provenance["launch_locale"] = session.launchArguments[index + 1]
        }
        if let device = try? await driver.deviceInfo() {
            report.provenance["device_id"] = device.id
            report.provenance["device_os"] = device.osVersion
        }
        return report
    }
}
