import Foundation

public struct StudioTestExportRequest: Codable, Sendable {
    public let test: StudioAuthoredTest
    public init(test: StudioAuthoredTest) {
        self.test = test
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
    public let ios: (any StudioCodeEmitting)?
    public let android: (any StudioCodeEmitting)?
    public init(ios: (any StudioCodeEmitting)? = nil, android: (any StudioCodeEmitting)? = nil) {
        self.ios = ios
        self.android = android
    }
}
