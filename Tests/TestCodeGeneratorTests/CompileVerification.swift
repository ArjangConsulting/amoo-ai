import Foundation
import XCTest

/// Shells out to real compilers so generated test source is checked for genuine compile
/// correctness, not just string-shape assertions. Each verification skips (rather than fails)
/// when its toolchain isn't available, since these depend on machine-local tooling
/// (Xcode + iOS Simulator SDK for Swift; kotlinc + a resolved Espresso classpath for Kotlin).
enum CompileVerification {
    static func verifySwiftCompiles(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let sdkPath = try? runCapturingOutput("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
            .trimmingCharacters(in: .whitespacesAndNewlines), sdkPath.isEmpty == false
        else {
            throw XCTSkip("iOS Simulator SDK not found — skipping Swift compile verification.")
        }
        let platformPath = try runCapturingOutput(
            "/usr/bin/xcrun",
            ["--sdk", "iphonesimulator", "--show-sdk-platform-path"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        let frameworksPath = "\(platformPath)/Developer/Library/Frameworks"
        // XCTest's Swift overlay (real functions backing XCTAssert*, since the underlying
        // Objective-C header only exposes them as C macros, which plain -F framework import
        // can't see) lives here, not under the framework itself.
        let overlayPath = "\(platformPath)/Developer/usr/lib"

        let sourceFile = try writeTempFile(source, extension: "swift")
        defer { try? FileManager.default.removeItem(at: sourceFile) }

        let result = run("/usr/bin/xcrun", [
            "swiftc", "-typecheck",
            "-sdk", sdkPath,
            "-target", "arm64-apple-ios18.0-simulator",
            "-F", frameworksPath,
            "-I", overlayPath,
            sourceFile.path
        ])

        if result.exitCode != 0 {
            XCTFail("Generated Swift did not compile:\n\(result.output)", file: file, line: line)
        }
    }

    static func verifyKotlinCompiles(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let kotlinc = commandPath("kotlinc") else {
            throw XCTSkip("kotlinc not installed — skipping Kotlin compile verification.")
        }
        let resolverScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TestCodeGeneratorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tooling/espresso-classpath/resolve.sh")
        guard FileManager.default.isExecutableFile(atPath: resolverScript.path) else {
            throw XCTSkip("Espresso classpath resolver script not found — skipping Kotlin compile verification.")
        }
        let classpathResult = run(resolverScript.path, [])
        let classpath = classpathResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard classpathResult.exitCode == 0, classpath.isEmpty == false else {
            throw XCTSkip(
                "Could not resolve an Espresso classpath (no network / Gradle unavailable?)"
                    + " — skipping Kotlin compile verification."
            )
        }

        let sourceFile = try writeTempFile(source, extension: "kt")
        defer { try? FileManager.default.removeItem(at: sourceFile) }
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        // AndroidX / Compose artifacts are compiled to JVM 11+ bytecode; kotlinc defaults to a 1.8
        // target and then refuses to inline their `inline` functions. A real AGP build targets 17,
        // so match that here.
        let result = run(kotlinc, ["-jvm-target", "17", "-cp", classpath, "-d", outputDir.path, sourceFile.path])
        if result.exitCode != 0 {
            XCTFail("Generated Kotlin did not compile:\n\(result.output)", file: file, line: line)
        }
    }

    private static func writeTempFile(_ contents: String, extension ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func commandPath(_ name: String) -> String? {
        let path = try? runCapturingOutput("/usr/bin/which", [name]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, path.isEmpty == false else { return nil }
        return path
    }

    /// For probing tool availability: throws if the command itself couldn't be found/run.
    private static func runCapturingOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
        let result = run(launchPath, arguments)
        guard result.exitCode == 0 else {
            throw CompileVerificationError.commandFailed(launchPath, result.output)
        }
        return result.output
    }

    /// For invoking compilers: never throws on a nonzero exit — a compile failure is the
    /// expected way this reports "the generated code is invalid," not a harness error.
    private static func run(_ launchPath: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
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
