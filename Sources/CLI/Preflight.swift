import Foundation
import GradleKit
import MobileTestingCore
import ProcessRunner
import SwiftyShell
import XcodeBuildKit

public enum PreflightPlatform: String, Sendable {
    case iOS = "ios"
    case android
    case all
}

public enum PreflightStatus: String, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
}

public struct PreflightCheck: Sendable, Equatable {
    public var id: String
    public var status: PreflightStatus
    public var message: String
    public var remediation: String

    public init(id: String, status: PreflightStatus, message: String, remediation: String) {
        self.id = id
        self.status = status
        self.message = message
        self.remediation = remediation
    }
}

public struct PreflightReport: Sendable, Equatable {
    public var platform: PreflightPlatform
    public var checks: [PreflightCheck]

    public init(platform: PreflightPlatform, checks: [PreflightCheck]) {
        self.platform = platform
        self.checks = checks
    }

    public var hasFailures: Bool {
        checks.contains(where: { $0.status == .fail })
    }
}

public protocol PreflightChecking: Sendable {
    func run(platform: PreflightPlatform) async -> PreflightReport
}

public struct DefaultPreflightChecker: PreflightChecking {
    private let shellContext: ShellContext

    public init(processRunner: any ProcessRunner = SystemProcessRunner()) {
        shellContext = ShellContext(
            executor: ProcessRunnerCommandExecutor(processRunner: processRunner)
        )
    }

    public func run(platform: PreflightPlatform) async -> PreflightReport {
        var checks: [PreflightCheck] = []

        if platform == .all || platform == .iOS {
            await checks.append(
                check(
                    id: "ios.xcode-select",
                    commandDescription: "xcode-select -p",
                    remediation: "Install Xcode Command Line Tools and select an active developer directory."
                ) {
                    try await XcodeSelect(context: shellContext).printPath().run().processResult
                }
            )
            await checks.append(
                check(
                    id: "ios.simctl",
                    commandDescription: "xcrun simctl list devices available --json",
                    remediation: "Install Xcode simulator runtimes and ensure `xcrun simctl` is available."
                ) {
                    let output = try await SimctlRunner(context: shellContext).listDevices()
                    return ProcessResult(exitCode: 0, stdout: output, stderr: "")
                }
            )
        }

        if platform == .all || platform == .android {
            await checks.append(
                check(
                    id: "android.adb",
                    commandDescription: "adb version",
                    remediation: "Install Android platform-tools and add `adb` to PATH."
                ) {
                    try await Adb(context: shellContext).rawArguments(["version"]).run().processResult
                }
            )
        }

        return PreflightReport(platform: platform, checks: checks)
    }

    private func check(
        id: String,
        commandDescription: String,
        remediation: String,
        run: () async throws -> ProcessResult
    ) async -> PreflightCheck {
        do {
            let result = try await run()
            if result.exitCode == 0 {
                return PreflightCheck(
                    id: id,
                    status: .pass,
                    message: "Command succeeded: \(commandDescription)",
                    remediation: remediation
                )
            }

            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
            return PreflightCheck(
                id: id,
                status: .fail,
                message:
                "Exit \(result.exitCode): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))",
                remediation: remediation
            )
        } catch {
            return PreflightCheck(
                id: id,
                status: .fail,
                message: "Execution failed: \(error)",
                remediation: remediation
            )
        }
    }
}

public func renderPreflightReport(_ report: PreflightReport) -> String {
    var lines: [String] = []
    let statusText =
        report.hasFailures
            ? colored("FAIL", .bold, .red)
            : colored("PASS", .bold, .green)
    lines.append("preflight \(statusText) [\(report.platform.rawValue)]")

    for check in report.checks {
        let badge =
            check.status == .pass
                ? colored("[PASS]", .green)
                : colored("[FAIL]", .red)
        lines.append("\(badge) \(check.id) - \(check.message)")
        if check.status == .fail {
            lines.append("  \(colored("remediation:", .yellow)) \(check.remediation)")
        }
    }

    return lines.joined(separator: "\n")
}
