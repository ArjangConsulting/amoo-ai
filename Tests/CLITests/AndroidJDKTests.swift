@testable import CLI
import Foundation
import XCTest

final class AndroidJDKTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("android-jdk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testReadsTheMajorVersionOutOfAReleaseFile() throws {
        let modern = try makeJDK(named: "temurin-21.jdk", javaVersion: "21.0.12")
        let legacy = try makeJDK(named: "legacy-8.jdk", javaVersion: "1.8.0_402")

        XCTAssertEqual(AndroidJDK.majorVersion(ofJavaHome: modern), 21)
        XCTAssertEqual(AndroidJDK.majorVersion(ofJavaHome: legacy), 8)
    }

    func testReportsNoVersionForADirectoryThatIsNotAJDK() {
        XCTAssertNil(AndroidJDK.majorVersion(ofJavaHome: root.path))
    }

    /// Homebrew's `openjdk` tracks the newest release, past what Gradle can run on, and it is what
    /// a machine with no explicit JAVA_HOME picks up — the case that fails deep inside Gradle with
    /// an unrelated-looking error.
    func testReplacesAJavaHomeThatIsTooNew() throws {
        let tooNew = try makeJDK(named: "openjdk-27.jdk", javaVersion: "27.0.1")
        _ = try makeJDK(named: "temurin-21.jdk", javaVersion: "21.0.12")

        let resolved = AndroidJDK.resolveJavaHome(
            environment: ["JAVA_HOME": tooNew],
            searchPaths: [root.path]
        )

        XCTAssertEqual(resolved, root.path + "/temurin-21.jdk/Contents/Home")
    }

    func testKeepsAJavaHomeThatIsAlreadySupported() throws {
        let supported = try makeJDK(named: "ms-17.jdk", javaVersion: "17.0.20")
        _ = try makeJDK(named: "temurin-21.jdk", javaVersion: "21.0.12")

        let resolved = AndroidJDK.resolveJavaHome(
            environment: ["JAVA_HOME": supported],
            searchPaths: [root.path]
        )

        XCTAssertEqual(resolved, supported)
    }

    func testPicksTheNewestSupportedJDKWhenSeveralAreInstalled() throws {
        _ = try makeJDK(named: "ms-17.jdk", javaVersion: "17.0.20")
        _ = try makeJDK(named: "temurin-21.jdk", javaVersion: "21.0.12")
        _ = try makeJDK(named: "openjdk-27.jdk", javaVersion: "27.0.1")

        let resolved = AndroidJDK.resolveJavaHome(environment: [:], searchPaths: [root.path])

        XCTAssertEqual(resolved, root.path + "/temurin-21.jdk/Contents/Home")
    }

    func testResolvesNothingWhenEveryInstalledJDKIsOutOfRange() throws {
        _ = try makeJDK(named: "openjdk-27.jdk", javaVersion: "27.0.1")
        _ = try makeJDK(named: "legacy-8.jdk", javaVersion: "1.8.0_402")

        XCTAssertNil(AndroidJDK.resolveJavaHome(environment: [:], searchPaths: [root.path]))
    }

    func testGradleEnvironmentOverridesOnlyJavaHome() throws {
        _ = try makeJDK(named: "temurin-21.jdk", javaVersion: "21.0.12")
        let tooNew = try makeJDK(named: "openjdk-27.jdk", javaVersion: "27.0.1")

        let environment = AndroidJDK.gradleEnvironment(
            environment: ["JAVA_HOME": tooNew, "PATH": "/usr/bin"],
            searchPaths: [root.path]
        )

        XCTAssertEqual(environment["JAVA_HOME"], root.path + "/temurin-21.jdk/Contents/Home")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    /// Leaving the environment untouched keeps Gradle's own "JAVA_HOME is not set" message,
    /// which is clearer than anything invented here.
    func testGradleEnvironmentIsUnchangedWhenNoSupportedJDKExists() {
        let environment = AndroidJDK.gradleEnvironment(
            environment: ["PATH": "/usr/bin"],
            searchPaths: [root.path]
        )

        XCTAssertEqual(environment, ["PATH": "/usr/bin"])
    }

    // MARK: - Helpers

    @discardableResult
    private func makeJDK(named name: String, javaVersion: String) throws -> String {
        let home = root.appendingPathComponent(name).appendingPathComponent("Contents/Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        IMPLEMENTOR="Test"
        JAVA_VERSION="\(javaVersion)"
        OS_ARCH="aarch64"
        """.write(to: home.appendingPathComponent("release"), atomically: true, encoding: .utf8)
        return home.path
    }
}
