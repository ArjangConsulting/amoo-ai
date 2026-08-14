import AmooCore
@testable import CompanionProtocol
import XCTest

final class CompanionClientDefaultsTests: XCTestCase {
    func testConvenienceMethodsDelegateToFullVariants() async throws {
        let client = DelegatingCompanionClient()

        try await client.tapElement(.init(id: "login"))
        let found = try await client.findElements(.init(label: "Login"))
        try await client.waitForElement(.init(id: "login"), timeout: Duration(milliseconds: 250))

        let tapElementCalls = await client.tapElementCalls()
        let findElementCalls = await client.findElementCalls()
        let waitCalls = await client.waitCalls()

        XCTAssertEqual(tapElementCalls.count, 1)
        XCTAssertEqual(tapElementCalls.first?.selector.id, "login")
        XCTAssertNil(tapElementCalls.first?.appID)
        XCTAssertEqual(tapElementCalls.first?.candidateBundleIDs, [])

        XCTAssertEqual(found, [ElementInfo(id: "match", label: "Login")])
        XCTAssertEqual(findElementCalls.count, 1)
        XCTAssertEqual(findElementCalls.first?.selector.label, "Login")
        XCTAssertNil(findElementCalls.first?.appID)
        XCTAssertEqual(findElementCalls.first?.candidateBundleIDs, [])

        XCTAssertEqual(waitCalls.count, 1)
        XCTAssertEqual(waitCalls.first?.selector.id, "login")
        XCTAssertEqual(waitCalls.first?.timeout, Duration(milliseconds: 250))
        XCTAssertNil(waitCalls.first?.appID)
        XCTAssertEqual(waitCalls.first?.candidateBundleIDs, [])
    }

    func testDefaultUnsupportedOperationsThrowNotImplemented() async {
        let client = MinimalCompanionClient()

        await assertNotImplemented("doubleTap") {
            try await client.doubleTap(at: Point(x: 1, y: 2))
        }
        await assertNotImplemented("longPress") {
            try await client.longPress(at: Point(x: 1, y: 2), duration: Duration(milliseconds: 500))
        }
        await assertNotImplemented("tapElement") {
            try await client.tapElement(.init(id: "login"), appID: nil, candidateBundleIDs: [])
        }
        await assertNotImplemented("pressHome") {
            try await client.pressHome()
        }
        await assertNotImplemented("scroll") {
            try await client.scroll(direction: .down, distance: 100)
        }
        await assertNotImplemented("clearText") {
            try await client.clearText(characterCount: 2)
        }
        await assertNotImplemented("getViewHierarchy") {
            _ = try await client.getViewHierarchy(appID: nil, candidateBundleIDs: [])
        }
        await assertNotImplemented("findElements") {
            _ = try await client.findElements(.init(id: "login"), appID: nil, candidateBundleIDs: [])
        }
        await assertNotImplemented("waitForElement") {
            try await client.waitForElement(
                .init(id: "login"),
                timeout: Duration(milliseconds: 250),
                appID: nil,
                candidateBundleIDs: []
            )
        }
        await assertNotImplemented("isKeyboardVisible") {
            _ = try await client.isKeyboardVisible()
        }
        await assertNotImplemented("takeScreenshot") {
            _ = try await client.takeScreenshot()
        }
        await assertNotImplemented("getInteractableElements") {
            _ = try await client.getInteractableElements()
        }
        await assertNotImplemented("findByDescription") {
            _ = try await client.findByDescription("login")
        }
    }
}

struct ElementQueryCall {
    let selector: ElementSelector
    let appID: String?
    let candidateBundleIDs: [String]
}

struct WaitElementCall {
    let selector: ElementSelector
    let timeout: Duration
    let appID: String?
    let candidateBundleIDs: [String]
}

private actor DelegatingCompanionClient: CompanionClient {
    private var recordedTapElementCalls: [ElementQueryCall] = []
    private var recordedFindElementCalls: [ElementQueryCall] = []
    private var recordedWaitCalls: [WaitElementCall] = []

    func startSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func endSession() async throws {}
    func tap(at point: Point) async throws {
        _ = point
    }

    func swipe(from: Point, to: Point, duration: Duration) async throws {
        _ = (from, to, duration)
    }

    func typeText(_ text: String) async throws {
        _ = text
    }

    func pressBack() async throws {}
    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "mock")
    }

    func tapElement(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws {
        recordedTapElementCalls.append(
            ElementQueryCall(selector: selector, appID: appID, candidateBundleIDs: candidateBundleIDs)
        )
    }

    func findElements(
        _ selector: ElementSelector,
        appID: String?,
        candidateBundleIDs: [String]
    ) async throws -> [ElementInfo] {
        recordedFindElementCalls.append(
            ElementQueryCall(selector: selector, appID: appID, candidateBundleIDs: candidateBundleIDs)
        )
        return [ElementInfo(id: "match", label: selector.label ?? "")]
    }

    func waitForElement(
        _ selector: ElementSelector,
        timeout: Duration,
        appID: String?,
        candidateBundleIDs: [String]
    ) async throws {
        recordedWaitCalls.append(
            WaitElementCall(selector: selector, timeout: timeout, appID: appID, candidateBundleIDs: candidateBundleIDs)
        )
    }

    func tapElementCalls() -> [ElementQueryCall] {
        recordedTapElementCalls
    }

    func findElementCalls() -> [ElementQueryCall] {
        recordedFindElementCalls
    }

    func waitCalls() -> [WaitElementCall] {
        recordedWaitCalls
    }
}

private actor MinimalCompanionClient: CompanionClient {
    func startSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func endSession() async throws {}
    func tap(at point: Point) async throws {
        _ = point
    }

    func swipe(from: Point, to: Point, duration: Duration) async throws {
        _ = (from, to, duration)
    }

    func typeText(_ text: String) async throws {
        _ = text
    }

    func pressBack() async throws {}
    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "mock")
    }
}

private func assertNotImplemented(
    _ expectedOperation: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: @escaping @Sendable () async throws -> Any
) async {
    do {
        _ = try await operation()
        XCTFail("Expected notImplemented error", file: file, line: line)
    } catch let error as AmooError {
        XCTAssertEqual(error, .notImplemented(expectedOperation), file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
