import AdbKit
import AmooCore
import AmooLogging
import Foundation
import SwiftyShell

extension AndroidCompanionConfig {
    /// The lowest Android API level the companion installs on. Mirrors `minSdk` in
    /// `CompanionApps/Android/app/build.gradle.kts`; a test keeps the two equal.
    static let minimumAPILevel = 26
}

private let logger = AmooLogger.forType(AndroidCompanionManager.self)

private let companionPackages = ["com.amoo.companion.test", "com.amoo.companion"]

extension AndroidCompanionManager {
    /// Installs the app and test APKs. A device below the companion's minimum API level fails before
    /// any install; an install adb rejects carries adb's own output, the likely cause and the
    /// supported next step. A signature or version clash with a previous amoo companion is repaired
    /// once by removing the amoo-owned packages, which hold no user data.
    func installAPKs(
        config: AndroidCompanionConfig,
        appApkPath: String,
        testApkPath: String,
        force: Bool = false
    ) async throws {
        let device = config.serial ?? "default device"
        let state = await deviceInstallState(config: config)
        let apiLevel = state.apiLevel
        logger.info(
            "Installing Android companion APKs",
            context: "action=install device=\(device) apiLevel=\(apiLevel.map(String.init) ?? "unknown")"
        )
        if let apiLevel, apiLevel < AndroidCompanionConfig.minimumAPILevel {
            let diagnosis = AndroidInstallDiagnosis.diagnose(
                output: "INSTALL_FAILED_OLDER_SDK", apiLevel: apiLevel
            )
            throw AndroidCompanionError.installFailed(
                diagnosis.message(label: "companion", serial: config.serial, apiLevel: apiLevel, output: "")
            )
        }
        let packages = ["app": "com.amoo.companion", "test": "com.amoo.companion.test"]
        for (label, apkPath) in [("app", appApkPath), ("test", testApkPath)] {
            // The device already holds these exact bytes: installing them again changes nothing and
            // is most of a warm start. `force` reinstalls regardless.
            if !force, let package = packages[label], let installed = state.installed[package],
               installed == sha256Hex(ofRegularFile: apkPath) {
                logger.info("Android companion APK already installed", context: "action=install label=\(label)")
                continue
            }
            var failure = try await runInstall(config: config, apkPath: apkPath)
            if let output = failure,
               AndroidInstallDiagnosis.diagnose(output: output, apiLevel: apiLevel).reinstallFixes {
                logger.info(
                    "Removing amoo companion packages before one reinstall attempt",
                    context: "action=reinstall device=\(device) label=\(label)"
                )
                await removeCompanionPackages(config: config)
                failure = try await runInstall(config: config, apkPath: apkPath)
            }
            if let output = failure {
                let diagnosis = AndroidInstallDiagnosis.diagnose(output: output, apiLevel: apiLevel)
                logger.error(
                    "Android companion install failed",
                    error: AndroidCompanionError.installFailed(diagnosis.code ?? "unknown"),
                    context: "action=install device=\(device) label=\(label) code=\(diagnosis.code ?? "none")"
                )
                throw AndroidCompanionError.installFailed(
                    diagnosis.message(label: label, serial: config.serial, apiLevel: apiLevel, output: output)
                )
            }
        }
        logger.info("Installed Android companion APKs", context: "action=install device=\(device)")
    }

    /// One round trip for everything an install decision needs: the API level on the first line,
    /// then `<package> <sha256>` for each companion package already on the device.
    static let installStateCommand = "getprop ro.build.version.sdk; "
        + "for p in com.amoo.companion com.amoo.companion.test; do "
        + "f=$(pm path $p 2>/dev/null | head -1 | cut -d: -f2); "
        + #"[ -n "$f" ] && echo "$p $(sha256sum "$f" 2>/dev/null | cut -d" " -f1)"; "#
        + "done; true"

    /// The device's `ro.build.version.sdk` (`nil` when unreadable) and the SHA-256 of each installed
    /// companion APK. A device without `sha256sum`, or without the packages, reports none installed.
    func deviceInstallState(config: AndroidCompanionConfig) async -> (apiLevel: Int?, installed: [String: String]) {
        let result = try? await Adb(context: shellContext)
            .serial(config.serial)
            .shell(Self.installStateCommand)
            .run()
            .processResult
        return Self.parseInstallState(result?.stdout ?? "")
    }

    static func parseInstallState(_ output: String) -> (apiLevel: Int?, installed: [String: String]) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var installed: [String: String] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: " ")
            // A SHA-256 is 64 hex digits; anything else is an error message, not a digest.
            guard fields.count == 2, fields[1].count == 64, fields[1].allSatisfy(\.isHexDigit) else { continue }
            installed[String(fields[0])] = String(fields[1]).lowercased()
        }
        return (lines.first.flatMap { Int($0) }, installed)
    }

    /// One `adb install -r`. The result is adb's combined output when it exited non-zero, and `nil`
    /// on success. SwiftyShell throws on a non-zero exit, so the output is taken from the thrown
    /// error rather than lost behind its one-line description.
    private func runInstall(
        config: AndroidCompanionConfig,
        apkPath: String
    ) async throws -> String? {
        do {
            let result = try await Adb(context: shellContext)
                .serial(config.serial)
                .install(apk: apkPath, replace: true)
                .run()
                .processResult
            guard result.exitCode != 0 else { return nil }
            return Self.combinedOutput(stdout: result.stdout, stderr: result.stderr)
        } catch let ShellError.exitFailure(_, output) {
            return Self.combinedOutput(stdout: output.stdout, stderr: output.stderr)
        } catch {
            throw AndroidCompanionError.installFailed(error.localizedDescription)
        }
    }

    private func removeCompanionPackages(config: AndroidCompanionConfig) async {
        for package in companionPackages {
            _ = try? await Adb(context: shellContext)
                .serial(config.serial)
                .uninstall(package: package)
                .run()
                .processResult
        }
    }

    static func combinedOutput(stdout: String, stderr: String) -> String {
        let parts = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }
}
