import AmooCore
import Foundation
import GradleKit
import ProcessRunner
import SwiftyShell

public enum PreflightPlatform: String, Sendable {
    case iOS = "ios"
    case android
    case all
}

public enum PreflightStatus: String, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    /// Something optional is missing. Reported, but does not fail preflight — used for
    /// tooling only some workflows need, like physical-device support.
    case warn = "WARN"
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
            await checks.append(contentsOf: iOSChecks())
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
            checks.append(androidJDKCheck())
        }

        return PreflightReport(platform: platform, checks: checks)
    }

    /// The companion's Gradle build needs a JDK in AGP's supported range. Reported here because
    /// a too-new JDK fails deep inside Gradle with an error that mentions neither.
    private func androidJDKCheck() -> PreflightCheck {
        let remediation = """
        Install a JDK between \(AndroidJDK.minimumMajorVersion) and \
        \(AndroidJDK.maximumMajorVersion) — `brew install --cask temurin@21` — or point \
        JAVA_HOME at one you already have. Homebrew's `openjdk` is too new for AGP.
        """
        guard let javaHome = AndroidJDK.resolveJavaHome() else {
            return PreflightCheck(
                id: "android.jdk",
                status: .fail,
                message: "No JDK \(AndroidJDK.minimumMajorVersion)–\(AndroidJDK.maximumMajorVersion) found."
                    + " The Android companion build will fail.",
                remediation: remediation
            )
        }
        let version = AndroidJDK.majorVersion(ofJavaHome: javaHome).map(String.init) ?? "unknown"
        return PreflightCheck(
            id: "android.jdk",
            status: .pass,
            message: "JDK \(version) at \(javaHome)",
            remediation: remediation
        )
    }

    /// Simulator tooling is required; physical-device tooling is opt-in and only warns,
    /// since most workflows never touch real hardware.
    private func iOSChecks() async -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        await checks.append(
            check(
                id: "ios.xcode-select",
                commandDescription: "xcode-select -p",
                remediation: "Install Xcode Command Line Tools and select an active developer directory."
            ) {
                // A plain `Command` rather than XcodeBuildKit's `XcodeSelect` (macOS-only type):
                // on Linux `xcode-select` genuinely isn't installed, so this fails the same way
                // any other missing-tool check does, through the same process-runner path.
                try await Command("xcode-select").args(["-p"]).run(in: shellContext).processResult
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
        await checks.append(
            check(
                id: "ios.devicectl",
                commandDescription: "xcrun devicectl list devices --json-output -",
                remediation: """
                Needed only for physical iOS devices. Requires Xcode 15 or later; \
                simulators do not use it.
                """,
                failureStatus: .warn
            ) {
                let output = try await DeviceCtlRunner(context: shellContext).listDevices()
                return ProcessResult(exitCode: 0, stdout: output, stderr: "")
            }
        )
        await checks.append(
            check(
                id: "ios.iproxy",
                commandDescription: "which iproxy",
                remediation: """
                Needed only for physical iOS devices, to tunnel to the companion over \
                USB — `devicectl` has no port forwarding of its own.
                Install with: brew install libimobiledevice
                (`iproxy` ships in libusbmuxd, which that formula pulls in and links.)
                """,
                failureStatus: .warn
            ) {
                try await Command("which").args(["iproxy"]).run(in: shellContext).processResult
            }
        )

        return checks
    }

    private func check(
        id: String,
        commandDescription: String,
        remediation: String,
        failureStatus: PreflightStatus = .fail,
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
                status: failureStatus,
                message:
                "Exit \(result.exitCode): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))",
                remediation: remediation
            )
        } catch {
            return PreflightCheck(
                id: id,
                status: failureStatus,
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
        let badge: String = switch check.status {
        case .pass: colored("[PASS]", .green)
        case .warn: colored("[WARN]", .yellow)
        case .fail: colored("[FAIL]", .red)
        }
        lines.append("\(badge) \(check.id) - \(check.message)")
        if check.status != .pass {
            lines.append("  \(colored("remediation:", .yellow)) \(check.remediation)")
        }
    }

    return lines.joined(separator: "\n")
}
