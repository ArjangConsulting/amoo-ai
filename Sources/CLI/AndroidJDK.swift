import Foundation

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
/// supported JDK themselves and hand it to Gradle.
enum AndroidJDK {
    /// Oldest JDK the companion's `sourceCompatibility`/`jvmTarget` of 17 can build on, and also
    /// AGP 9.3's own minimum.
    static let minimumMajorVersion = 17
    /// Newest JVM Gradle 9.5 can run on.
    static let maximumMajorVersion = 26

    /// Directories macOS installs JDKs into. `/usr/libexec/java_home` searches the same two.
    static func defaultSearchPaths(homeDirectory: String = NSHomeDirectory()) -> [String] {
        [
            "/Library/Java/JavaVirtualMachines",
            homeDirectory + "/Library/Java/JavaVirtualMachines"
        ]
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
        if let current = environment["JAVA_HOME"],
           let version = majorVersion(ofJavaHome: current, fileManager: fileManager),
           isSupported(version) {
            return current
        }
        return installedJDKs(searchPaths: searchPaths, fileManager: fileManager)
            .filter { isSupported($0.majorVersion) }
            // Newest supported wins, so a machine with both 17 and 21 builds on 21.
            .max(by: { $0.majorVersion < $1.majorVersion })?
            .path
    }

    /// The environment to run Gradle in — the caller's, with `JAVA_HOME` corrected when a
    /// supported JDK was found and the current one is unusable.
    static func gradleEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        searchPaths: [String] = defaultSearchPaths(),
        fileManager: FileManager = .default
    ) -> [String: String] {
        guard let javaHome = resolveJavaHome(
            environment: environment,
            searchPaths: searchPaths,
            fileManager: fileManager
        ) else { return environment }

        var updated = environment
        updated["JAVA_HOME"] = javaHome
        return updated
    }

    static func isSupported(_ majorVersion: Int) -> Bool {
        (minimumMajorVersion ... maximumMajorVersion).contains(majorVersion)
    }

    struct InstalledJDK: Equatable {
        var path: String
        var majorVersion: Int
    }

    static func installedJDKs(
        searchPaths: [String] = defaultSearchPaths(),
        fileManager: FileManager = .default
    ) -> [InstalledJDK] {
        searchPaths.flatMap { searchPath -> [InstalledJDK] in
            let entries = (try? fileManager.contentsOfDirectory(atPath: searchPath)) ?? []
            return entries.sorted().compactMap { entry in
                let home = searchPath + "/" + entry + "/Contents/Home"
                guard let version = majorVersion(ofJavaHome: home, fileManager: fileManager) else {
                    return nil
                }
                return InstalledJDK(path: home, majorVersion: version)
            }
        }
    }

    /// Reads the major version out of a JDK's `release` file, which every distribution ships
    /// with a `JAVA_VERSION="21.0.12"` line.
    static func majorVersion(ofJavaHome javaHome: String, fileManager: FileManager = .default) -> Int? {
        let releasePath = javaHome + "/release"
        guard fileManager.fileExists(atPath: releasePath),
              let contents = try? String(contentsOfFile: releasePath, encoding: .utf8)
        else { return nil }

        for line in contents.split(separator: "\n") where line.hasPrefix("JAVA_VERSION=") {
            let raw = line
                .dropFirst("JAVA_VERSION=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r"))
            // "1.8.0_402" for 8, "21.0.12" for everything modern.
            let components = raw.split(separator: ".")
            guard let first = components.first, let major = Int(first) else { return nil }
            if major == 1, components.count > 1 {
                return Int(components[1])
            }
            return major
        }
        return nil
    }
}
