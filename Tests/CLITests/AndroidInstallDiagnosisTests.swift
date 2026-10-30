@testable import CLI
import Foundation
import XCTest

final class AndroidInstallDiagnosisTests: XCTestCase {
    func testOlderSdkNamesTheLevelAndTheMinimum() {
        let diagnosis = AndroidInstallDiagnosis.diagnose(
            output: "adb: failed to install app.apk: Failure [INSTALL_FAILED_OLDER_SDK]", apiLevel: 24
        )
        XCTAssertEqual(diagnosis.code, "INSTALL_FAILED_OLDER_SDK")
        XCTAssertTrue(diagnosis.cause.contains("API 24"))
        XCTAssertTrue(diagnosis.cause.contains("API \(AndroidCompanionConfig.minimumAPILevel)"))
        XCTAssertFalse(diagnosis.reinstallFixes)
    }

    func testSignatureClashIsRepairedByReinstalling() {
        for code in ["INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_VERSION_DOWNGRADE"] {
            let diagnosis = AndroidInstallDiagnosis.diagnose(output: "Failure [\(code): signatures do not match]")
            XCTAssertEqual(diagnosis.code, code)
            XCTAssertTrue(diagnosis.reinstallFixes, code)
        }
    }

    func testParseFailuresAreRecognisedAsCodes() {
        let diagnosis = AndroidInstallDiagnosis.diagnose(output: "Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]")
        XCTAssertEqual(diagnosis.code, "INSTALL_PARSE_FAILED_NO_CERTIFICATES")
    }

    func testUnknownCodeStillGivesARecoveryAndNeverReinstalls() {
        let diagnosis = AndroidInstallDiagnosis.diagnose(output: "Failure [INSTALL_FAILED_SOMETHING_NEW]")
        XCTAssertEqual(diagnosis.code, "INSTALL_FAILED_SOMETHING_NEW")
        XCTAssertFalse(diagnosis.reinstallFixes)
        XCTAssertTrue(diagnosis.recovery.contains("amoo doctor --cli-only --json"))
    }

    func testOfflineDeviceWithoutACodePointsAtStartupStatus() {
        let diagnosis = AndroidInstallDiagnosis.diagnose(output: "adb: device offline")
        XCTAssertNil(diagnosis.code)
        XCTAssertTrue(diagnosis.recovery.contains("session_startup_status"))
    }

    func testSilentFailureSaysAdbPrintedNothing() {
        let diagnosis = AndroidInstallDiagnosis.diagnose(output: "")
        let message = diagnosis.message(label: "app", serial: "emulator-5554", apiLevel: 37, output: "")
        XCTAssertTrue(message.contains("emulator-5554, API 37"))
        XCTAssertTrue(message.contains("(adb printed nothing)"))
    }

    func testRecoveryNeverSuggestsRawAdbOrBulkKills() {
        let outputs = [
            "INSTALL_FAILED_OLDER_SDK", "INSTALL_FAILED_DEPRECATED_SDK_VERSION", "INSTALL_FAILED_NO_MATCHING_ABIS",
            "INSTALL_FAILED_INSUFFICIENT_STORAGE", "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
            "INSTALL_FAILED_USER_RESTRICTED", "device offline", ""
        ]
        for output in outputs {
            let recovery = AndroidInstallDiagnosis.diagnose(output: output).recovery
            XCTAssertFalse(recovery.contains("adb "), output)
            XCTAssertFalse(recovery.contains("--kill-stale"), output)
        }
    }

    func testMessageCarriesAdbOutputCauseAndRecovery() {
        let output = "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"
        let message = AndroidInstallDiagnosis.diagnose(output: output)
            .message(label: "test", serial: nil, apiLevel: nil, output: output)
        XCTAssertTrue(message.hasPrefix("Failed to install Android test APK:\n"))
        XCTAssertTrue(message.contains(output))
        XCTAssertTrue(message.contains("Likely cause:"))
        XCTAssertTrue(message.contains("Recovery:"))
    }

    func testCombinedOutputDropsBlanksAndDuplicates() {
        XCTAssertEqual(AndroidCompanionManager.combinedOutput(stdout: "x\n", stderr: "x"), "x")
        XCTAssertEqual(AndroidCompanionManager.combinedOutput(stdout: "out", stderr: "err"), "err\nout")
        XCTAssertEqual(AndroidCompanionManager.combinedOutput(stdout: " ", stderr: ""), "")
    }

    func testMinimumAPILevelMatchesTheCompanionMinSdk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let gradle = try String(
            contentsOf: root.appending(path: "CompanionApps/Android/app/build.gradle.kts"), encoding: .utf8
        )
        XCTAssertTrue(
            gradle.contains("minSdk = \(AndroidCompanionConfig.minimumAPILevel)"),
            "update AndroidCompanionConfig.minimumAPILevel together with minSdk"
        )
    }
}
