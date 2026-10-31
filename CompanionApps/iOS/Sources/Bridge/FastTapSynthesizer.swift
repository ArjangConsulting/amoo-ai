import Foundation
import ObjectiveC.runtime
import UIKit

/// Injects a touch through XCTest's runner daemon without `XCUICoordinate.tap()`'s implicit
/// confirmation and quiescence work. All symbols are resolved at runtime so a changed XCTest
/// falls back to the public gesture path instead of preventing the companion from loading.
@MainActor
enum FastTapSynthesizer {
    private static let tapDuration: TimeInterval = 0.05

    static var isAvailable: Bool {
        objc_lookUpClass("XCSynthesizedEventRecord") != nil
            && objc_lookUpClass("XCPointerEventPath") != nil
            && NSClassFromString("XCTRunnerDaemonSession") != nil
    }

    static func tap(at point: CGPoint, orientation: UIInterfaceOrientation, displayID: UInt? = nil) async throws {
        let event = try makeEvent(orientation: orientation, displayID: displayID)
        let path = try makeTouchPath(at: point)
        try lift(path: path, at: tapDuration)
        try add(path: path, to: event)
        try await synthesize(event: event)
    }

    /// A single-finger touch that lands on `start`, stays for `hold`, travels to `end` over `travel`,
    /// and stays for `settle` before lifting. With `end == nil` it is a press held for `hold`.
    static func touch(
        from start: CGPoint,
        to end: CGPoint?,
        hold: TimeInterval,
        travel: TimeInterval,
        settle: TimeInterval,
        orientation: UIInterfaceOrientation,
        displayID: UInt?
    ) async throws {
        let event = try makeEvent(orientation: orientation, displayID: displayID)
        let path = try makeTouchPath(at: start)
        var offset = hold
        if let end {
            try move(path: path, to: start, at: offset)
            let duration = max(travel, 0.01)
            let steps = max(2, Int(duration / 0.016))
            for step in 1 ... steps {
                let fraction = Double(step) / Double(steps)
                let point = CGPoint(
                    x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction
                )
                try move(path: path, to: point, at: offset + duration * fraction)
            }
            offset += duration
        }
        offset += settle
        try lift(path: path, at: offset)
        try add(path: path, to: event)
        try await synthesize(event: event)
    }

    private static func move(path: NSObject, to point: CGPoint, at offset: TimeInterval) throws {
        let selector = NSSelectorFromString("moveToPoint:atOffset:")
        guard path.responds(to: selector) else {
            throw FastTapError.unavailable(NSStringFromSelector(selector))
        }
        let implementation = path.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, CGPoint, TimeInterval) -> Void
        unsafeBitCast(implementation, to: Method.self)(path, selector, point, offset)
    }

    private static func makeEvent(orientation: UIInterfaceOrientation, displayID: UInt?) throws -> NSObject {
        guard let eventClass = objc_lookUpClass("XCSynthesizedEventRecord") else {
            throw FastTapError.unavailable("XCSynthesizedEventRecord")
        }
        let allocated = eventClass.alloc() as AnyObject
        if let displayID {
            let displaySelector = NSSelectorFromString("initWithName:displayID:interfaceOrientation:")
            if allocated.responds(to: displaySelector) {
                let implementation = allocated.method(for: displaySelector)
                typealias DisplayMethod = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> NSObject
                return unsafeBitCast(implementation, to: DisplayMethod.self)(
                    allocated,
                    displaySelector,
                    "Single-Finger Touch Action",
                    displayID,
                    UInt(orientation.rawValue)
                )
            }
        }
        let selector = NSSelectorFromString("initWithName:interfaceOrientation:")
        guard allocated.responds(to: selector) else {
            throw FastTapError.unavailable(NSStringFromSelector(selector))
        }
        let implementation = allocated.method(for: selector)
        typealias Method = @convention(c) (AnyObject, Selector, NSString, UInt) -> NSObject
        return unsafeBitCast(implementation, to: Method.self)(
            allocated,
            selector,
            "Single-Finger Touch Action",
            UInt(orientation.rawValue)
        )
    }

    private static func makeTouchPath(at point: CGPoint) throws -> NSObject {
        guard let pathClass = objc_lookUpClass("XCPointerEventPath") else {
            throw FastTapError.unavailable("XCPointerEventPath")
        }
        let allocated = pathClass.alloc() as AnyObject
        let selector = NSSelectorFromString("initForTouchAtPoint:offset:")
        guard allocated.responds(to: selector) else {
            throw FastTapError.unavailable(NSStringFromSelector(selector))
        }
        let implementation = allocated.method(for: selector)
        typealias Method = @convention(c) (AnyObject, Selector, CGPoint, TimeInterval) -> NSObject
        return unsafeBitCast(implementation, to: Method.self)(allocated, selector, point, 0)
    }

    private static func lift(path: NSObject, at offset: TimeInterval) throws {
        let selector = NSSelectorFromString("liftUpAtOffset:")
        guard path.responds(to: selector) else {
            throw FastTapError.unavailable(NSStringFromSelector(selector))
        }
        let implementation = path.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, TimeInterval) -> Void
        unsafeBitCast(implementation, to: Method.self)(path, selector, offset)
    }

    private static func add(path: NSObject, to event: NSObject) throws {
        let selector = NSSelectorFromString("addPointerEventPath:")
        guard event.responds(to: selector) else {
            throw FastTapError.unavailable(NSStringFromSelector(selector))
        }
        let implementation = event.method(for: selector)
        typealias Method = @convention(c) (NSObject, Selector, NSObject) -> Void
        unsafeBitCast(implementation, to: Method.self)(event, selector, path)
    }

    private static func synthesize(event: NSObject) async throws {
        guard let sessionClass = NSClassFromString("XCTRunnerDaemonSession") else {
            throw FastTapError.unavailable("XCTRunnerDaemonSession")
        }
        let sharedSelector = NSSelectorFromString("sharedSession")
        guard sessionClass.responds(to: sharedSelector) else {
            throw FastTapError.unavailable(NSStringFromSelector(sharedSelector))
        }
        let sharedImplementation = sessionClass.method(for: sharedSelector)
        typealias SharedMethod = @convention(c) (AnyClass, Selector) -> NSObject
        let session = unsafeBitCast(sharedImplementation, to: SharedMethod.self)(sessionClass, sharedSelector)

        let proxySelector = NSSelectorFromString("daemonProxy")
        guard let proxy = session.perform(proxySelector)?.takeUnretainedValue() as? NSObject else {
            throw FastTapError.unavailable(NSStringFromSelector(proxySelector))
        }
        let synthesizeSelector = NSSelectorFromString("_XCT_synthesizeEvent:completion:")
        guard proxy.responds(to: synthesizeSelector) else {
            throw FastTapError.unavailable(NSStringFromSelector(synthesizeSelector))
        }
        let implementation = proxy.method(for: synthesizeSelector)
        typealias Method = @convention(c) (
            NSObject,
            Selector,
            NSObject,
            @escaping (Error?) -> Void
        ) -> Void
        let method = unsafeBitCast(implementation, to: Method.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            method(proxy, synthesizeSelector, event) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

private enum FastTapError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(symbol): "XCTest fast-tap symbol unavailable: \(symbol)"
        }
    }
}
