@testable import CLI
import Foundation
import StudioProtocol
import TestCodeGenerator
import TestSession
import XCTest

final class StudioTestGeneratorTests: XCTestCase {
    private func generator(store: FileSessionStore) -> CLIStudioTestGenerator {
        var emitters = StudioCodeEmitters()
        emitters.register(XCUITestEmitter(), for: .init(platform: .ios))
        emitters.register(EspressoEmitter(), for: .init(platform: .android))
        return CLIStudioTestGenerator(pipeline: StudioTestGenerationPipeline(emitters: emitters), store: store)
    }

    private func plan(warnings: [StudioPlanWarning]? = nil) -> StudioAuthoredTest {
        StudioAuthoredTest(
            formatVersion: 1,
            name: "Sign In",
            description: "",
            platform: .ios,
            steps: [.init(id: "step-0", instruction: "Tap", expected: "Tapped")],
            compiledPlan: .init(
                compiler: "session",
                compilerVersion: "1",
                toolOperations: [.init(id: "step-0", tool: "tap_element", arguments: ["id": "login"])],
                warnings: warnings
            )
        )
    }

    func testASessionsPlanGeneratesMappedSource() async throws {
        let scratch = try makeScratchDirectory()
        let store = FileSessionStore(root: scratch.url)
        let directory = store.directory(for: "session-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan()).write(to: directory.appending(path: "plan.json"))

        let result = try await generator(store: store).generate(.init(
            sessionId: "session-1",
            projectPath: scratch.url.path
        ))

        let generated = try XCTUnwrap(result.generated)
        XCTAssertNil(result.problem)
        XCTAssertEqual(generated.language, "swift")
        XCTAssertEqual(generated.sourceMap.map(\.operationId), ["step-0"])
        XCTAssertTrue(generated.source.contains("\"login\""))
    }

    func testASessionWithoutAPlanIsCompiledFromItsReport() async throws {
        let scratch = try makeScratchDirectory()
        let store = FileSessionStore(root: scratch.url)
        let action = SessionAction(
            timestamp: Date(),
            toolName: "tap_element",
            arguments: ["id": "login"],
            result: "Tapped",
            isError: false
        )
        let report = SessionReport(
            sessionID: "session-2",
            appID: "dev.app",
            deviceID: "sim",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 1,
            actionCount: 1,
            errorCount: 0,
            isActive: false,
            actions: [action]
        )
        await store.save(report)

        let result = try await generator(store: store).generate(.init(
            sessionId: "session-2",
            testName: "Login",
            projectPath: scratch.url.path
        ))

        XCTAssertEqual(result.test.compiledPlan?.toolOperations?.first?.tool, "tap_element")
        XCTAssertNotNil(result.generated)
    }

    func testIncompleteAndRedactedPlansReturnProblemsInsteadOfFailing() async throws {
        let scratch = try makeScratchDirectory()
        let generator = generator(store: FileSessionStore(root: scratch.url))
        let excluded = StudioPlanWarning(kind: .excluded, actionIndex: 3, toolName: "pinch", reason: "no equivalent")
        let redacted = StudioPlanWarning(kind: .redacted, actionIndex: 0, toolName: "set_text", reason: "secret")

        let incomplete = try await generator.generate(.init(
            test: plan(warnings: [excluded]),
            projectPath: scratch.url.path
        ))
        let allowed = try await generator.generate(.init(
            test: plan(warnings: [excluded]),
            allowIncomplete: true,
            projectPath: scratch.url.path
        ))
        let secret = try await generator.generate(.init(
            test: plan(warnings: [redacted]),
            allowIncomplete: true,
            projectPath: scratch.url.path
        ))

        XCTAssertEqual(incomplete.problem?.kind, .incomplete)
        XCTAssertEqual(incomplete.problem?.warnings, [excluded])
        XCTAssertNil(incomplete.generated)
        XCTAssertNotNil(allowed.generated)
        XCTAssertEqual(secret.problem?.kind, .redacted)
    }

    func testMissingSessionsAreReported() async throws {
        let scratch = try makeScratchDirectory()
        do {
            _ = try await generator(store: FileSessionStore(root: scratch.url)).generate(.init(sessionId: "missing"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("missing"))
        }
    }

    func testAppContextIsDiscoveredBesideAnXcodeProject() throws {
        let scratch = try makeScratchDirectory()
        let project = scratch.url.appending(path: "App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        XCTAssertEqual(
            CLIStudioTestGenerator.discoveryDirectory(project.path).standardizedFileURL,
            scratch.url.standardizedFileURL
        )
        XCTAssertEqual(
            CLIStudioTestGenerator.discoveryDirectory(scratch.url.path).standardizedFileURL,
            scratch.url.standardizedFileURL
        )
    }
}
