@testable import CLI
import TestCommons
import XCTest

final class CompanionHealthWatchTests: XCTestCase {
    private actor Probes {
        var responses: [Bool]
        private(set) var count = 0
        init(_ responses: [Bool]) {
            self.responses = responses
        }

        func next() -> Bool {
            count += 1
            return responses.isEmpty ? true : responses.removeFirst()
        }
    }

    func testTransientFailuresResetAfterASuccessfulProbe() async {
        let probes = Probes([false, false, true, false, false, false])
        await waitForCompanionAPIUnavailable(pollInterval: .milliseconds(1), failureLimit: 3) {
            await probes.next()
        }
        let count = await probes.count
        XCTAssertEqual(count, 6)
    }

    func testHealthyAPIDoesNotRestartAndCancellationStopsWatching() async throws {
        let probes = Probes([])
        let watcher = Task {
            await waitForCompanionAPIUnavailable(pollInterval: .milliseconds(1), failureLimit: 3) {
                await probes.next()
            }
        }
        defer { watcher.cancel() }
        _ = try await waitUntil(timeout: .seconds(1), operation: { await probes.count }, matching: { $0 >= 5 })
        watcher.cancel()
        await watcher.value
    }
}
