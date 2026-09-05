import AmooCore
import Foundation

/// A managed, app-scoped testing session. Holds the driver bound to this
/// session and records every tool invocation. Closing the session terminates
/// the app under test and releases the gRPC connection — but leaves the
/// companion process running for reuse.
public actor TestSession {
    nonisolated public let id: String
    nonisolated public let appID: String
    nonisolated public let deviceID: String
    nonisolated public let platform: Platform
    nonisolated public let startedAt: Date
    nonisolated public let launchArguments: [String]
    nonisolated public let launchEnvironment: [String: String]
    nonisolated public let testName: String?
    nonisolated public let driver: any PlatformDriver

    public private(set) var endedAt: Date?
    public private(set) var actions: [SessionAction] = []
    public private(set) var isActive: Bool = true
    public private(set) var codegenIntent: SessionCodegenIntent?

    public func setCodegenIntent(_ intent: SessionCodegenIntent) {
        codegenIntent = intent
    }

    public private(set) var redactor: ArtifactRedactor

    public func registerSecret(_ value: String) {
        redactor.register(value)
    }

    private var recentElements: [RecordedElement] = []

    private let cleanup: @Sendable () async -> Void

    public init(
        id: String,
        appID: String,
        deviceID: String,
        platform: Platform,
        driver: any PlatformDriver,
        startedAt: Date = Date(),
        launchArguments: [String] = [],
        launchEnvironment: [String: String] = [:],
        testName: String? = nil,
        cleanup: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.appID = appID
        self.deviceID = deviceID
        self.platform = platform
        self.driver = driver
        self.startedAt = startedAt
        self.launchArguments = launchArguments
        self.launchEnvironment = launchEnvironment
        self.testName = testName
        self.cleanup = cleanup
        redactor = ArtifactRedactor(environment: launchEnvironment, arguments: launchArguments)
    }

    public func record(_ incoming: SessionAction) {
        guard isActive else { return }
        var action = incoming
        if action.toolName == "swipe", let origin = Self.swipeOrigin(action),
           let target = Self.resolveTarget(at: origin, from: recentElements) {
            action = action.recordingGestureTarget(target)
        }
        actions.append(action)
        if action.observedElements.isEmpty == false {
            recentElements = action.observedElements
        }
        if Self.invalidatesElementGeometry(action.toolName) {
            recentElements = []
        }
    }

    private static func swipeOrigin(_ action: SessionAction) -> RecordedPoint? {
        guard let x = action.arguments["from_x"].flatMap(Double.init),
              let y = action.arguments["from_y"].flatMap(Double.init) else { return nil }
        return RecordedPoint(x: x, y: y)
    }

    public static func resolveTarget(
        at point: RecordedPoint,
        from elements: [RecordedElement]
    ) -> RecordedGestureTarget? {
        let addressable = elements.filter { $0.id?.isEmpty == false || $0.label?.isEmpty == false }
        let containing = addressable.filter { $0.frame?.contains(point) == true }
        if containing.count == 1, let element = containing.first {
            return RecordedGestureTarget(
                elementID: element.id,
                elementLabel: element.label,
                elementType: element.elementType,
                resolution: .frameContainsPoint
            )
        }
        let nearby = addressable.compactMap { element -> (RecordedElement, Double)? in
            guard let hit = element.hitPoint else { return nil }
            return (element, hypot(hit.x - point.x, hit.y - point.y))
        }.sorted { $0.1 < $1.1 }
        guard let best = nearby.first, best.1 <= 160,
              nearby.count == 1 || nearby[1].1 - best.1 >= 20 else { return nil }
        return RecordedGestureTarget(
            elementID: best.0.id,
            elementLabel: best.0.label,
            elementType: best.0.elementType,
            resolution: .nearestHitPoint
        )
    }

    private static func invalidatesElementGeometry(_ tool: String) -> Bool {
        [
            "tap",
            "tap_element",
            "double_tap",
            "long_press",
            "swipe",
            "swipe_in_direction",
            "scroll",
            "drag",
            "type_text",
            "set_text",
            "fill_field",
            "press_back",
            "device_launch_app"
        ].contains(tool)
    }

    /// Terminates the app under test (best-effort) and releases the gRPC
    /// connection. Safe to call multiple times.
    public func close() async {
        guard isActive else { return }
        isActive = false
        endedAt = Date()
        try? await driver.terminateApp(appID: appID)
        await cleanup()
    }
}
