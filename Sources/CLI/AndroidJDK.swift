import Foundation
import MobileDevices

/// Finds a JDK the Android companion's Gradle build can actually run on.
///
/// The supported range is the intersection of what the build's two pinned tools accept: AGP 9.3
/// requires JDK 17 or newer, and Gradle 9.5 runs on JVM 17 through 26 (27+ is not yet supported).
/// A JDK outside that window fails partway through with errors that name neither Java nor the JDK,
/// so resolving it up front is cheaper than reading the eventual stack trace. Homebrew's `openjdk`
/// tracks the newest release, so on a machine with no explicit `JAVA_HOME` this matters.
///
/// The cap used to be AGP's — AGP 8.7 could not run on anything past 21. That constraint left with
/// the AGP 9 upgrade; the cap is now Gradle's.
///
/// Rather than make every caller export `JAVA_HOME` by hand, the build entry points resolve a
/// supported JDK themselves and hand it to Gradle. Discovery is MobileDevices' `JavaRuntimes`;
/// the supported range is the companion's, so it lives here.
enum AndroidJDK {
    /// Oldest JDK the companion's `sourceCompatibility`/`jvmTarget` of 17 can build on, and also
    /// AGP 9.3's own minimum.
    static let minimumMajorVersion = 17
    /// Newest JVM Gradle 9.5 can run on.
    static let maximumMajorVersion = 26

    static var supported: ClosedRange<Int> {
        minimumMajorVersion ... maximumMajorVersion
    }

    /// Directories JDKs install into on this host (`JavaRuntimes.defaultSearchPaths`).
    static func defaultSearchPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        JavaRuntimes.defaultSearchPaths(homeDirectory: homeDirectory)
    }

    /// The `JAVA_HOME` to run Gradle with, or `nil` to leave the caller's environment alone.
    ///
    /// An existing `JAVA_HOME` inside the supported range is always kept — a deliberate choice
    /// by the user or by CI outranks anything found by scanning.
    static func resolveJavaHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchPaths: [String] = defaultSearchPaths(),
        fileManager: FileManager = .default
    ) -> String? {
        JavaRuntimes(searchPaths: searchPaths)
            .resolveJavaHome(supported: supported, environment: environment, fileManager: fileManager)
    }

    /// The environment to run Gradle in — the caller's, with `JAVA_HOME` corrected when a
    /// supported JDK was found and the current one is unusable.
    static func gradleEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchPaths: [String] = defaultSearchPaths(),
        fileManager: FileManager = .default
    ) -> [String: String] {
        JavaRuntimes(searchPaths: searchPaths).environment(
            supported: supported,
            base: environment,
            fileManager: fileManager
        )
    }

    static func isSupported(_ majorVersion: Int) -> Bool {
        supported.contains(majorVersion)
    }

    /// The major version from a JDK's `release` file.
    static func majorVersion(ofJavaHome javaHome: String, fileManager: FileManager = .default) -> Int? {
        JavaRuntimes.majorVersion(ofJavaHome: javaHome, fileManager: fileManager)
    }
}
