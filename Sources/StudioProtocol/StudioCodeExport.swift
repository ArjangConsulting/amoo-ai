import AmooCore
import Foundation

public struct StudioTestExportRequest: Codable, Sendable {
    public let test: StudioAuthoredTest
    /// A caller may supply app context at export time instead of persisting it in the test plan.
    public let testContext: StudioTestContext?
    public init(test: StudioAuthoredTest, testContext: StudioTestContext? = nil) {
        self.test = test; self.testContext = testContext
    }
}

public struct StudioTestExportResult: Codable, Equatable, Sendable {
    public let fileName: String
    public let source: String
    public init(fileName: String, source: String) {
        self.fileName = fileName
        self.source = source
    }
}

/// Emits standalone native UI test source (e.g. XCUITest, Espresso) from a compiled Studio plan.
/// Declared here so `LiveStudioAutomationService` can accept an emitter without this module
/// depending on the concrete emitters, which themselves depend on this module's types.
public protocol StudioCodeEmitting: Sendable {
    func generate(_ test: StudioAuthoredTest) throws -> StudioTestExportResult
}

public struct StudioCodeEmitters: Sendable {
    public struct PlatformToolkitKey: Hashable, Sendable {
        public let platform: Platform
        public let toolkit: UIToolkit

        public init(platform: Platform, toolkit: UIToolkit = .view) {
            self.platform = platform
            self.toolkit = toolkit
        }
    }

    private var emitters: [PlatformToolkitKey: any StudioCodeEmitting]

    public init() {
        emitters = [:]
    }

    public init(ios: (any StudioCodeEmitting)? = nil, android: (any StudioCodeEmitting)? = nil) {
        emitters = [:]
        if let ios {
            emitters[.init(platform: .ios)] = ios
        }
        if let android {
            emitters[.init(platform: .android)] = android
        }
    }

    public mutating func register(_ emitter: any StudioCodeEmitting, for key: PlatformToolkitKey) {
        emitters[key] = emitter
    }

    public func emitter(for platform: Platform, toolkit: UIToolkit = .view) -> (any StudioCodeEmitting)? {
        emitters[.init(platform: platform, toolkit: toolkit)]
    }
}
