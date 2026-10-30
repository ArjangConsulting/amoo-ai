import AdbKit
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
        testApkPath: String
    ) async throws {
        let device = config.serial ?? "default device"
        let apiLevel = await deviceAPILevel(config: config)
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
        for (label, apkPath) in [("app", appApkPath), ("test", testApkPath)] {
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

    /// The device's `ro.build.version.sdk`, or `nil` when it cannot be read.
    func deviceAPILevel(config: AndroidCompanionConfig) async -> Int? {
        let result = try? await Adb(context: shellContext)
            .serial(config.serial)
            .getprop("ro.build.version.sdk")
            .run()
            .processResult
        return result.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
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
