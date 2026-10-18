// swiftlint:disable multiline_arguments
import Foundation
import TestCommons
import XCTest

/// Shells out to real compilers so generated test source is checked for genuine compile
/// correctness, not just string-shape assertions. Each verification skips (rather than fails)
/// when its toolchain isn't available, since these depend on machine-local tooling
/// (Xcode + iOS Simulator SDK for Swift; kotlinc + a resolved Espresso classpath for Kotlin).
enum CompileVerification {
    static func verifySwiftCompiles(
        _ source: String,
        additionalImportPaths: [String] = [],
        swiftVersion: Int = 5,
        extraArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try swiftTypecheck(
            source, additionalImportPaths: additionalImportPaths,
            swiftVersion: swiftVersion, extraArguments: extraArguments
        )
        if result.exitCode != 0 {
            XCTFail("Generated Swift did not compile:\n\(result.output)", file: file, line: line)
        }
    }

    /// Compiles `source` to SIL against the iOS Simulator SDK and returns the compiler's verdict, for
    /// callers that expect a failure (proving a check would catch the bug it exists for).
    ///
    /// `-emit-sil` rather than `-typecheck`: region-isolation diagnostics ("sending 'self' risks
    /// causing data races") come from the SIL passes, so a type-check alone passes code that a real
    /// Swift 6 UI-test target rejects.
    ///
    /// `AMOO_COMPILE_DEVELOPER_DIR` runs the check with another Xcode's toolchain, so the same
    /// generated source can be verified under each supported Swift version.
    static func swiftTypecheck(
        _ source: String,
        additionalImportPaths: [String] = [],
        swiftVersion: Int = 5,
        extraArguments: [String] = []
    ) throws -> (exitCode: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        if let developerDir = environment["AMOO_COMPILE_DEVELOPER_DIR"], !developerDir.isEmpty {
            environment["DEVELOPER_DIR"] = developerDir
        }
        guard
            let sdkPath = try? runCapturingOutput(
                "/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], environment: environment
            )
            .trimmingCharacters(in: .whitespacesAndNewlines), sdkPath.isEmpty == false
        else {
            throw XCTSkip("iOS Simulator SDK not found — skipping Swift compile verification.")
        }
        let platformPath = try runCapturingOutput(
            "/usr/bin/xcrun",
            ["--sdk", "iphonesimulator", "--show-sdk-platform-path"],
            environment: environment
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let frameworksPath = "\(platformPath)/Developer/Library/Frameworks"
        // XCTest's Swift overlay (real functions backing XCTAssert*, since the underlying
        // Objective-C header only exposes them as C macros, which plain -F framework import
        // can't see) lives here, not under the framework itself.
        let overlayPath = "\(platformPath)/Developer/usr/lib"

        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let sourceFile = try directory.write(Data(source.utf8), named: "fixture.swift")

        return run(
            "/usr/bin/xcrun",
            [
                "swiftc", "-emit-sil", "-o", "/dev/null", "-swift-version", String(swiftVersion),
                "-sdk", sdkPath,
                "-target", "arm64-apple-ios18.0-simulator",
                "-F", frameworksPath,
                "-I", overlayPath
            ] + extraArguments + [sourceFile.path] + additionalImportPaths.flatMap { ["-I", $0] },
            environment: environment
        )
    }

    static func verifyKotlinCompiles(
        _ source: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard let kotlinc = commandPath("kotlinc") else {
            throw XCTSkip("kotlinc not installed — skipping Kotlin compile verification.")
        }
        // Up from this file through TestCodeGeneratorTests/ and Tests/ to the repo root.
        let resolverScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tooling/espresso-classpath/resolve.sh")
        guard FileManager.default.isExecutableFile(atPath: resolverScript.path) else {
            throw XCTSkip(
                "Espresso classpath resolver script not found — skipping Kotlin compile verification."
            )
        }
        let classpathResult = run(resolverScript.path, [])
        let classpath = classpathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard classpathResult.exitCode == 0, classpath.isEmpty == false else {
            throw XCTSkip(
                "Could not resolve an Espresso classpath (no network / Gradle unavailable?)"
                    + " — skipping Kotlin compile verification."
            )
        }

        let directory = try TemporaryDirectory()
        defer { try? directory.remove() }
        let sourceFile = try directory.write(Data(source.utf8), named: "fixture.kt")
        let outputDir = directory.url.appendingPathComponent("classes")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: false)

        // AndroidX / Compose artifacts are compiled to JVM 11+ bytecode; kotlinc defaults to a 1.8
        // target and then refuses to inline their `inline` functions. A real AGP build targets 17,
        // so match that here.
        let result = run(
            kotlinc, ["-jvm-target", "17", "-cp", classpath, "-d", outputDir.path, sourceFile.path]
        )
        if result.exitCode != 0 {
            XCTFail("Generated Kotlin did not compile:\n\(result.output)", file: file, line: line)
        }
    }

    private static func commandPath(_ name: String) -> String? {
        let path = try? runCapturingOutput("/usr/bin/which", [name]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let path, path.isEmpty == false else { return nil }
        return path
    }

    /// For probing tool availability: throws if the command itself couldn't be found/run.
    private static func runCapturingOutput(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) throws -> String {
        let result = run(launchPath, arguments, environment: environment)
        guard result.exitCode == 0 else {
            throw CompileVerificationError.commandFailed(launchPath, result.output)
        }
        return result.output
    }

    /// For invoking compilers: never throws on a nonzero exit — a compile failure is the
    /// expected way this reports "the generated code is invalid," not a harness error.
    private static func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String]? = nil
    ) -> (
        exitCode: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch \(launchPath): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }
}

enum CompileVerificationError: Error {
    case commandFailed(String, String)
}

// swiftlint:enable multiline_arguments
