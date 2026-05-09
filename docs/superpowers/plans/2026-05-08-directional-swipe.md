# Directional Swipe Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire up `swipe(direction:)` end-to-end across proto → iOS companion → Android companion → host drivers → MCP tool.

**Architecture:** New `SwipeInDirection` RPC with `SwipeDirectionRequest` proto message (direction + optional distance/duration/element). iOS companion uses XCUITest native `swipeLeft()` etc.; Android companion uses UIAutomator2 `device.swipe()`. Host adds the RPC to `CompanionRPCClient` and wires it to `GestureActions.swipe(direction:distance:duration:)`.

**Tech Stack:** Swift/gRPC (grpc-swift v2), Kotlin/UIAutomator2, SwiftProtobuf, XCTest/XCUITest.

---

### Task 1: Add proto message and RPC

**Files:**
- Modify: `Protos/actions.proto`
- Modify: `CompanionApps/Android/app/src/main/proto/actions.proto`

- [ ] **Step 1: Add `SwipeDirectionRequest` and `SwipeInDirection` RPC to `Protos/actions.proto`**

In the `CompanionService` service block, add after `rpc Swipe`:
```protobuf
  rpc SwipeInDirection (SwipeDirectionRequest) returns (ActionResponse);
```

In the `// Gesture messages` section, add after the `SwipeRequest` block:
```protobuf
message SwipeDirectionRequest {
  Direction direction = 1;
  float distance = 2;
  int32 duration_ms = 3;
  ElementSelector selector = 4;
}
```

- [ ] **Step 2: Apply the same changes to the Android companion proto**

The Android companion has its own copy at `CompanionApps/Android/app/src/main/proto/actions.proto`. Apply the identical two changes (new RPC in service block + new message in gesture messages section).

- [ ] **Step 3: Verify main Swift package compiles with new proto types**

```bash
swift build
```
Expected: Build succeeds. The `GRPCProtobufGenerator` plugin auto-regenerates from `Protos/`. You should see `MobileTesting_SwipeDirectionRequest` and `MobileTesting_CompanionService.Method.SwipeInDirection` available in the build output.

- [ ] **Step 4: Commit**

```bash
git add Protos/actions.proto CompanionApps/Android/app/src/main/proto/actions.proto
git commit -m "feat: add SwipeDirectionRequest proto message and SwipeInDirection RPC"
```

---

### Task 2: Manually add SwipeInDirection to iOS companion generated proto stubs

The iOS companion (`CompanionApps/iOS/`) uses pre-generated Swift proto stubs that are checked in. Since `protoc-gen-swift` is not installed, add the generated code manually.

**Files:**
- Modify: `CompanionApps/iOS/GeneratedProtos/actions.pb.swift`
- Modify: `CompanionApps/iOS/GeneratedProtos/actions.grpc.swift`

#### actions.pb.swift additions

- [ ] **Step 1: Add `MobileTesting_SwipeDirectionRequest` struct**

Find the line containing `public struct MobileTesting_ScrollRequest: Sendable {` (currently line ~260). Insert before it:

```swift
public struct MobileTesting_SwipeDirectionRequest: Sendable {
    public var direction: MobileTesting_Direction = .unspecified
    public var distance: Float = 0
    public var durationMs: Int32 = 0
    public var selector: MobileTesting_ElementSelector {
        get { _selector ?? MobileTesting_ElementSelector() }
        set { _selector = newValue }
    }
    public var hasSelector: Bool { _selector != nil }
    public mutating func clearSelector() { _selector = nil }
    public var unknownFields = SwiftProtobuf.UnknownStorage()
    public init() {}
    fileprivate var _selector: MobileTesting_ElementSelector?
}
```

- [ ] **Step 2: Add `SwiftProtobuf.Message` conformance extension**

Find the `extension MobileTesting_ScrollRequest: SwiftProtobuf.Message` block (currently line ~860). Insert before it:

```swift
extension MobileTesting_SwipeDirectionRequest: SwiftProtobuf.Message, SwiftProtobuf._MessageImplementationBase,
    SwiftProtobuf._ProtoNameProviding
{
    public static let protoMessageName: String = _protobuf_package + ".SwipeDirectionRequest"
    public static let _protobuf_nameMap = SwiftProtobuf._NameMap(bytecode: "\0\u{1}direction\0\u{1}distance\0\u{2}duration_ms\0\u{1}selector\0")

    public mutating func decodeMessage(decoder: inout some SwiftProtobuf.Decoder) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularEnumField(value: &direction)
            case 2: try decoder.decodeSingularFloatField(value: &distance)
            case 3: try decoder.decodeSingularInt32Field(value: &durationMs)
            case 4: try decoder.decodeSingularMessageField(value: &_selector)
            default: break
            }
        }
    }

    public func traverse(visitor: inout some SwiftProtobuf.Visitor) throws {
        if direction != .unspecified {
            try visitor.visitSingularEnumField(value: direction, fieldNumber: 1)
        }
        if distance.bitPattern != 0 {
            try visitor.visitSingularFloatField(value: distance, fieldNumber: 2)
        }
        if durationMs != 0 {
            try visitor.visitSingularInt32Field(value: durationMs, fieldNumber: 3)
        }
        if let v = _selector {
            try visitor.visitSingularMessageField(value: v, fieldNumber: 4)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    public static func == (
        lhs: MobileTesting_SwipeDirectionRequest,
        rhs: MobileTesting_SwipeDirectionRequest
    ) -> Bool {
        if lhs.direction != rhs.direction { return false }
        if lhs.distance != rhs.distance { return false }
        if lhs.durationMs != rhs.durationMs { return false }
        if lhs._selector != rhs._selector { return false }
        if lhs.unknownFields != rhs.unknownFields { return false }
        return true
    }
}
```

#### actions.grpc.swift additions (9 locations)

Each insertion mirrors the adjacent `swipe` block exactly, substituting `SwipeInDirection`/`swipeInDirection`/`MobileTesting_SwipeDirectionRequest`.

- [ ] **Step 3: Add `Method.SwipeInDirection` enum**

Find `/// Namespace for "Drag" metadata.` block ending at `}` (~line 178). Insert after it:

```swift
        /// Namespace for "SwipeInDirection" metadata.
        public enum SwipeInDirection: Sendable {
            public typealias Input = MobileTesting_SwipeDirectionRequest
            public typealias Output = MobileTesting_ActionResponse
            public static let descriptor = GRPCCore.MethodDescriptor(
                service: GRPCCore.ServiceDescriptor(fullyQualifiedService: "mobile.testing.v1.CompanionService"),
                method: "SwipeInDirection"
            )
        }
```

- [ ] **Step 4: Add `SwipeInDirection.descriptor` to the `descriptors` array**

Find `Drag.descriptor,` in the `descriptors` array (~line 362). Add after it:
```swift
            SwipeInDirection.descriptor,
```

- [ ] **Step 5: Add to `StreamingServiceProtocol` (line ~524)**

After:
```swift
        func swipe(
            request: GRPCCore.StreamingServerRequest<MobileTesting_SwipeRequest>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.StreamingServerResponse<MobileTesting_ActionResponse>
```
Insert:
```swift
        func swipeInDirection(
            request: GRPCCore.StreamingServerRequest<MobileTesting_SwipeDirectionRequest>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.StreamingServerResponse<MobileTesting_ActionResponse>
```

- [ ] **Step 6: Add to `ServiceProtocol` (line ~915)**

After:
```swift
        func swipe(
            request: GRPCCore.ServerRequest<MobileTesting_SwipeRequest>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.ServerResponse<MobileTesting_ActionResponse>
```
Insert:
```swift
        func swipeInDirection(
            request: GRPCCore.ServerRequest<MobileTesting_SwipeDirectionRequest>,
            context: GRPCCore.ServerContext
        ) async throws -> GRPCCore.ServerResponse<MobileTesting_ActionResponse>
```

- [ ] **Step 7: Add to `SimpleServiceProtocol` (line ~1304)**

After:
```swift
        func swipe(
            request: MobileTesting_SwipeRequest,
            context: GRPCCore.ServerContext
        ) async throws -> MobileTesting_ActionResponse
```
Insert:
```swift
        func swipeInDirection(
            request: MobileTesting_SwipeDirectionRequest,
            context: GRPCCore.ServerContext
        ) async throws -> MobileTesting_ActionResponse
```

- [ ] **Step 8: Add default streaming impl bridging to ServiceProtocol (line ~1937)**

After:
```swift
    func swipe(
        request: GRPCCore.StreamingServerRequest<MobileTesting_SwipeRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<MobileTesting_ActionResponse> {
        let response = try await swipe(
            request: GRPCCore.ServerRequest(stream: request),
            context: context
        )
        return GRPCCore.StreamingServerResponse(single: response)
    }
```
Insert:
```swift
    func swipeInDirection(
        request: GRPCCore.StreamingServerRequest<MobileTesting_SwipeDirectionRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<MobileTesting_ActionResponse> {
        let response = try await swipeInDirection(
            request: GRPCCore.ServerRequest(stream: request),
            context: context
        )
        return GRPCCore.StreamingServerResponse(single: response)
    }
```

- [ ] **Step 9: Add default `ServiceProtocol` impl bridging to `SimpleServiceProtocol` (line ~2232)**

After:
```swift
    func swipe(
        request: GRPCCore.ServerRequest<MobileTesting_SwipeRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<MobileTesting_ActionResponse> {
        try await GRPCCore.ServerResponse<MobileTesting_ActionResponse>(
            message: swipe(request: request.message, context: context),
            metadata: [:]
        )
    }
```
Insert:
```swift
    func swipeInDirection(
        request: GRPCCore.ServerRequest<MobileTesting_SwipeDirectionRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<MobileTesting_ActionResponse> {
        try await GRPCCore.ServerResponse<MobileTesting_ActionResponse>(
            message: swipeInDirection(request: request.message, context: context),
            metadata: [:]
        )
    }
```

- [ ] **Step 10: Add router registration (after the `Swipe` router block ~line 1657)**

After:
```swift
        router.registerHandler(
            forMethod: MobileTesting_CompanionService.Method.Swipe.descriptor,
            deserializer: GRPCProtobuf.ProtobufDeserializer<MobileTesting_SwipeRequest>(),
            serializer: GRPCProtobuf.ProtobufSerializer<MobileTesting_ActionResponse>(),
            handler: { request, context in
                try await self.swipe(request: request, context: context)
            }
        )
```
Insert:
```swift
        router.registerHandler(
            forMethod: MobileTesting_CompanionService.Method.SwipeInDirection.descriptor,
            deserializer: GRPCProtobuf.ProtobufDeserializer<MobileTesting_SwipeDirectionRequest>(),
            serializer: GRPCProtobuf.ProtobufSerializer<MobileTesting_ActionResponse>(),
            handler: { request, context in
                try await self.swipeInDirection(request: request, context: context)
            }
        )
```

- [ ] **Step 11: Add to `ClientProtocol` (after swipe<Result> at line ~2628)**

After the `func swipe<Result: Sendable>` block in `ClientProtocol`, insert:
```swift
        func swipeInDirection<Result: Sendable>(
            request: GRPCCore.ClientRequest<MobileTesting_SwipeDirectionRequest>,
            serializer: some GRPCCore.MessageSerializer<MobileTesting_SwipeDirectionRequest>,
            deserializer: some GRPCCore.MessageDeserializer<MobileTesting_ActionResponse>,
            options: GRPCCore.CallOptions,
            onResponse handleResponse: @Sendable @escaping (GRPCCore
                .ClientResponse<MobileTesting_ActionResponse>) async throws -> Result
        ) async throws -> Result
```

- [ ] **Step 12: Add to the `Client` struct (after swipe<Result> at line ~3254)**

After the `public func swipe<Result: Sendable>` concrete implementation, insert:
```swift
        public func swipeInDirection<Result: Sendable>(
            request: GRPCCore.ClientRequest<MobileTesting_SwipeDirectionRequest>,
            serializer: some GRPCCore.MessageSerializer<MobileTesting_SwipeDirectionRequest>,
            deserializer: some GRPCCore.MessageDeserializer<MobileTesting_ActionResponse>,
            options: GRPCCore.CallOptions = .defaults,
            onResponse handleResponse: @Sendable @escaping (GRPCCore
                .ClientResponse<MobileTesting_ActionResponse>) async throws -> Result = { response in
                try response.message
            }
        ) async throws -> Result {
            try await client.unary(
                request: request,
                descriptor: MobileTesting_CompanionService.Method.SwipeInDirection.descriptor,
                serializer: serializer,
                deserializer: deserializer,
                options: options,
                onResponse: handleResponse
            )
        }
```

- [ ] **Step 13: Add convenience method to `ClientProtocol` extension (after swipe at line ~4029)**

After the `func swipe<Result: Sendable>` convenience (taking `ClientRequest`, no serializer params), insert:
```swift
    func swipeInDirection<Result: Sendable>(
        request: GRPCCore.ClientRequest<MobileTesting_SwipeDirectionRequest>,
        options: GRPCCore.CallOptions = .defaults,
        onResponse handleResponse: @Sendable @escaping (GRPCCore
            .ClientResponse<MobileTesting_ActionResponse>) async throws -> Result = { response in
            try response.message
        }
    ) async throws -> Result {
        try await swipeInDirection(
            request: request,
            serializer: GRPCProtobuf.ProtobufSerializer<MobileTesting_SwipeDirectionRequest>(),
            deserializer: GRPCProtobuf.ProtobufDeserializer<MobileTesting_ActionResponse>(),
            options: options,
            onResponse: handleResponse
        )
    }
```

- [ ] **Step 14: Add message-level convenience method (after swipe at line ~4744)**

After the `func swipe<Result: Sendable>(_ message: MobileTesting_SwipeRequest, ...)` convenience, insert:
```swift
    func swipeInDirection<Result: Sendable>(
        _ message: MobileTesting_SwipeDirectionRequest,
        metadata: GRPCCore.Metadata = [:],
        options: GRPCCore.CallOptions = .defaults,
        onResponse handleResponse: @Sendable @escaping (GRPCCore
            .ClientResponse<MobileTesting_ActionResponse>) async throws -> Result = { response in
            try response.message
        }
    ) async throws -> Result {
        let request = GRPCCore.ClientRequest<MobileTesting_SwipeDirectionRequest>(
            message: message,
            metadata: metadata
        )
        return try await swipeInDirection(
            request: request,
            options: options,
            onResponse: handleResponse
        )
    }
```

- [ ] **Step 15: Commit**

```bash
git add CompanionApps/iOS/GeneratedProtos/
git commit -m "feat: manually add SwipeInDirection to iOS companion generated proto stubs"
```

---

### Task 3: iOS companion — XCUITestBridge + GestureHandler + CompanionServiceProvider

**Files:**
- Modify: `CompanionApps/iOS/Sources/Bridge/XCUITestBridge.swift`
- Modify: `CompanionApps/iOS/Sources/Handlers/GestureHandler.swift`
- Modify: `CompanionApps/iOS/Sources/Server/CompanionServiceProvider.swift`

- [ ] **Step 1: Add `swipeInDirection` to `XCUITestBridge`**

In `XCUITestBridge.swift`, add after the `scroll` method (line ~59):

```swift
    func swipeInDirection(
        _ direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) {
        if id != nil || label != nil || containsText != nil {
            let allElements = collectedElements(in: app)
            for element in allElements
                where matchesElement(element, id: id, label: label, containsText: containsText)
            {
                guard element.exists else { continue }
                switch direction {
                case .up: element.swipeUp()
                case .down: element.swipeDown()
                case .left: element.swipeLeft()
                case .right: element.swipeRight()
                }
                return
            }
        }
        switch direction {
        case .up: app.swipeUp()
        case .down: app.swipeDown()
        case .left: app.swipeLeft()
        case .right: app.swipeRight()
        }
    }
```

Note: `collectedElements(in:)` and `matches(element:id:label:containsText:)` are private helpers that already exist in `XCUITestBridge`. Use those exact names.

- [ ] **Step 2: Add delegation method to `GestureHandler`**

In `GestureHandler.swift`, add after `scroll`:

```swift
    func swipeInDirection(
        direction: ScrollDirection,
        id: String?,
        label: String?,
        containsText: String?
    ) async {
        await bridge.swipeInDirection(direction, id: id, label: label, containsText: containsText)
    }
```

- [ ] **Step 3: Add capability and handler to `CompanionServiceProvider`**

In `CompanionServiceProvider.swift`, add `"action.swipeInDirection"` to the capabilities list:

```swift
("action.swipeInDirection", .required),
```

Add after the existing `swipe` handler method:

```swift
    func swipeInDirection(
        request: MobileTesting_SwipeDirectionRequest,
        context _: ServerContext
    ) async throws -> MobileTesting_ActionResponse {
        let direction: ScrollDirection = switch request.direction {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        default: .down
        }
        let id = request.selector.id.isEmpty ? nil : request.selector.id
        let label = request.selector.label.isEmpty ? nil : request.selector.label
        let containsText = request.selector.containsText.isEmpty ? nil : request.selector.containsText
        await gesture.swipeInDirection(
            direction: direction,
            id: request.hasSelector ? id : nil,
            label: request.hasSelector ? label : nil,
            containsText: request.hasSelector ? containsText : nil
        )
        return successResponse()
    }
```

- [ ] **Step 4: Commit**

```bash
git add CompanionApps/iOS/Sources/
git commit -m "feat: add swipeInDirection to iOS companion bridge, handler, and service"
```

---

### Task 4: Android companion — UIAutomatorBridge + GestureHandler + CompanionServiceImpl

**Files:**
- Modify: `CompanionApps/Android/app/src/androidTest/java/com/manman/companion/bridge/UIAutomatorBridge.kt`
- Modify: `CompanionApps/Android/app/src/androidTest/java/com/manman/companion/handlers/GestureHandler.kt`
- Modify: `CompanionApps/Android/app/src/androidTest/java/com/manman/companion/server/CompanionServiceImpl.kt`

- [ ] **Step 1: Add `swipeInDirection` to `UIAutomatorBridge`**

In `UIAutomatorBridge.kt`, add after the `scroll` method:

```kotlin
    fun swipeInDirection(
        direction: Direction,
        distance: Int,
        durationMs: Int,
        resourceId: String?,
        text: String?
    ): Boolean {
        val steps = (durationMs / 5).coerceAtLeast(1)
        val (w, h) = device.displayWidth to device.displayHeight

        if (resourceId != null || text != null) {
            val selector = androidx.test.uiautomator.UiSelector().let { s ->
                var result = s
                if (resourceId != null) result = result.resourceId(resourceId)
                if (text != null) result = result.text(text)
                result
            }
            val obj = device.findObject(selector)
            if (obj != null && obj.exists()) {
                val bounds = obj.bounds
                val cx = bounds.centerX()
                val cy = bounds.centerY()
                val (dx, dy) = directionDelta(direction, distance)
                return device.swipe(cx, cy, cx + dx, cy + dy, steps)
            }
        }

        val cx = w / 2
        val cy = h / 2
        val (dx, dy) = directionDelta(direction, distance)
        return device.swipe(cx, cy, cx + dx, cy + dy, steps)
    }

    private fun directionDelta(direction: Direction, distance: Int): Pair<Int, Int> = when (direction) {
        Direction.UP -> 0 to -distance
        Direction.DOWN -> 0 to distance
        Direction.LEFT -> -distance to 0
        Direction.RIGHT -> distance to 0
    }
```

- [ ] **Step 2: Add delegation to `GestureHandler`**

In `GestureHandler.kt`, add after `scroll`:

```kotlin
    fun swipeInDirection(
        direction: Direction,
        distance: Int,
        durationMs: Int,
        resourceId: String?,
        text: String?
    ): Boolean {
        return bridge.swipeInDirection(direction, distance, durationMs, resourceId, text)
    }
```

- [ ] **Step 3: Add `swipeInDirection` override to `CompanionServiceImpl`**

In `CompanionServiceImpl.kt`, add after `override suspend fun swipe`:

```kotlin
    override suspend fun swipeInDirection(request: SwipeDirectionRequest): ActionResponse {
        val direction = request.direction.coreDirection()
        val distance = if (request.distance > 0) request.distance.toInt() else 300
        val durationMs = if (request.durationMs > 0) request.durationMs else 400
        val resourceId = if (request.hasSelector() && request.selector.id.isNotBlank())
            request.selector.id else null
        val label = if (request.hasSelector() && request.selector.label.isNotBlank())
            request.selector.label else null
        return actionResponse(
            gesture.swipeInDirection(direction, distance, durationMs, resourceId, label),
            "swipeInDirection failed"
        )
    }
```

Also add `"action.swipeInDirection"` to the capabilities list:
```kotlin
capability("action.swipeInDirection", CapabilityTier.CAPABILITY_TIER_REQUIRED),
```

- [ ] **Step 4: Commit**

```bash
git add CompanionApps/Android/
git commit -m "feat: add swipeInDirection to Android companion bridge, handler, and service"
```

---

### Task 5: Host — GestureActions protocol + CompanionRPCClient + GRPCCompanionClient (TDD)

**Files:**
- Modify: `Sources/MobileTestingCore/Protocols.swift`
- Modify: `Sources/CompanionProtocol/GRPCCompanionClient.swift`
- Modify: `Sources/CompanionProtocol/CompanionClient.swift`
- Test: `Tests/CompanionProtocolTests/CompanionProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

In `CompanionProtocolTests.swift`, add after `testNewActionsDelegate`:

```swift
    func testSwipeInDirectionDelegatesToRPC() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.swipeInDirection(.left, distance: 250, duration: Duration(milliseconds: 350), element: nil)

        let req = await rpcClient.swipeDirectionRequest
        XCTAssertEqual(req?.direction, .left)
        XCTAssertEqual(req?.distance, 250)
        XCTAssertEqual(req?.durationMs, 350)
        XCTAssertFalse(req?.hasSelector ?? true)

        let calls = await rpcClient.actionCalls
        XCTAssertTrue(calls.contains("swipeInDirection"))
    }

    func testSwipeInDirectionWithElementSelector() async throws {
        let rpcClient = MockRPCClient()
        let client = GRPCCompanionClient(
            connection: .init(host: "localhost", port: 22087),
            rpcClient: rpcClient
        )

        try await client.swipeInDirection(
            .right,
            distance: 200,
            duration: Duration(milliseconds: 300),
            element: ElementSelector(id: "card-list")
        )

        let req = await rpcClient.swipeDirectionRequest
        XCTAssertEqual(req?.direction, .right)
        XCTAssertTrue(req?.hasSelector ?? false)
        XCTAssertEqual(req?.selector.id, "card-list")
    }
```

Also add to `MockRPCClient`:
```swift
    var swipeDirectionRequest: MobileTesting_SwipeDirectionRequest?
```

And add the method:
```swift
    func swipeInDirection(_ request: MobileTesting_SwipeDirectionRequest) async throws -> MobileTesting_ActionResponse {
        swipeDirectionRequest = request
        actionCalls.append("swipeInDirection")
        return successResponse()
    }
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
swift test --filter CompanionProtocolTests/testSwipeInDirectionDelegatesToRPC 2>&1 | tail -5
```
Expected: Compiler error — `swipeInDirection` does not exist yet.

- [ ] **Step 3: Add element-targeted swipe to `GestureActions` protocol**

In `Sources/MobileTestingCore/Protocols.swift`, in `GestureActions`:
- Add after `func swipe(direction: Direction, distance: Double, duration: Duration) async throws`:
```swift
    func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws
```

In `public extension GestureActions`:
- Change the existing `swipe(direction:distance:duration:)` default from throwing `.notImplemented` to forwarding:
```swift
    func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await swipe(direction: direction, distance: distance, duration: duration, element: nil)
    }
```
- Add a default for the new 4-param method:
```swift
    func swipe(direction _: Direction, distance _: Double, duration _: Duration, element _: ElementSelector?) async throws {
        throw MobileTestingError.notImplemented("swipe(direction:element:)")
    }
```

- [ ] **Step 4: Add `swipeInDirection` to `CompanionRPCClient` protocol**

In `GRPCCompanionClient.swift`, in `CompanionRPCClient` protocol, add after `func swipe`:
```swift
    func swipeInDirection(_ request: MobileTesting_SwipeDirectionRequest) async throws -> MobileTesting_ActionResponse
```

- [ ] **Step 5: Implement in `GeneratedCompanionRPCClient`**

In the `GeneratedCompanionRPCClient` struct, add after `func swipe`:
```swift
    package func swipeInDirection(_ request: MobileTesting_SwipeDirectionRequest) async throws
        -> MobileTesting_ActionResponse {
        try await client.swipeInDirection(request)
    }
```

- [ ] **Step 6: Implement in `InMemoryCompanionRPCClient`**

In `InMemoryCompanionRPCClient`, add after `func swipe`:
```swift
    package func swipeInDirection(_ request: MobileTesting_SwipeDirectionRequest) async throws
        -> MobileTesting_ActionResponse {
        _ = request
        return successActionResponse()
    }
```

- [ ] **Step 7: Implement in `LiveCompanionRPCClient`**

In `LiveCompanionRPCClient`, add after `func swipe`:
```swift
    package func swipeInDirection(_ request: MobileTesting_SwipeDirectionRequest) async throws
        -> MobileTesting_ActionResponse {
        try await client.swipeInDirection(request)
    }
```

- [ ] **Step 8: Add `swipeInDirection` to `CompanionClient` protocol**

In `Sources/CompanionProtocol/CompanionClient.swift`, add after `func swipe(from:to:duration:)`:
```swift
    func swipeInDirection(_ direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws
```

Add a default `.notImplemented` in `public extension CompanionClient`:
```swift
    func swipeInDirection(_: Direction, distance _: Double, duration _: Duration, element _: ElementSelector?) async throws {
        throw MobileTestingError.notImplemented("swipeInDirection")
    }
```

- [ ] **Step 9: Implement in `GRPCCompanionClient`**

In `GRPCCompanionClient`, in the `// MARK: - Gestures` section, add after `swipe(from:to:duration:)`:
```swift
    public func swipeInDirection(
        _ direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws {
        var request = MobileTesting_SwipeDirectionRequest()
        request.direction = direction.protoDirection
        request.distance = Float(distance)
        request.durationMs = Int32(duration.milliseconds)
        if let element {
            request.selector = element.protoSelector
        }

        let response = try await rpcClient.swipeInDirection(request)
        try validate(response: response, action: "swipeInDirection")
    }
```

- [ ] **Step 10: Run test to confirm it passes**

```bash
swift test --filter CompanionProtocolTests/testSwipeInDirectionDelegatesToRPC 2>&1 | tail -5
swift test --filter CompanionProtocolTests/testSwipeInDirectionWithElementSelector 2>&1 | tail -5
```
Expected: Both pass.

- [ ] **Step 11: Run full suite**

```bash
swift test 2>&1 | tail -5
```
Expected: All existing tests still pass.

- [ ] **Step 12: Commit**

```bash
git add Sources/MobileTestingCore/Protocols.swift \
        Sources/CompanionProtocol/CompanionClient.swift \
        Sources/CompanionProtocol/GRPCCompanionClient.swift \
        Tests/CompanionProtocolTests/CompanionProtocolTests.swift
git commit -m "feat: wire swipeInDirection through CompanionRPCClient and GRPCCompanionClient"
```

---

### Task 6: IOSDriver + AndroidDriver (TDD)

**Files:**
- Modify: `Sources/IOSDriver/IOSDriver.swift`
- Modify: `Sources/AndroidDriver/AndroidDriver.swift`
- Test: `Tests/IOSDriverTests/IOSDriverTests.swift`
- Test: `Tests/AndroidDriverTests/AndroidDriverTests.swift`

- [ ] **Step 1: Write failing tests for IOSDriver**

`MockCompanionClient` in `IOSDriverTests.swift` uses per-type tracking arrays. Add a new tracking array and two test methods.

In the `MockCompanionClient` actor definition (around line 472), add:
```swift
    private var _swipeDirections: [(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?)] = []
```

Add a read accessor:
```swift
    var swipeDirections: [(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?)] {
        _swipeDirections
    }
```

Add the implementation method (the protocol default throws `.notImplemented`; we need a real impl here):
```swift
    func swipeInDirection(
        _ direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws {
        _swipeDirections.append((direction, distance, duration, element))
    }
```

Add two tests to `IOSDriverTests`:
```swift
    func testSwipeDirectionDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion)
        try await driver.swipe(direction: .left, distance: 300, duration: Duration(milliseconds: 400))
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .left)
        XCTAssertEqual(swipes[0].distance, 300)
        XCTAssertNil(swipes[0].element)
    }

    func testSwipeDirectionWithElementDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion)
        try await driver.swipe(
            direction: .right,
            distance: 200,
            duration: Duration(milliseconds: 300),
            element: ElementSelector(id: "scroll-view")
        )
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .right)
        XCTAssertEqual(swipes[0].element?.id, "scroll-view")
    }
```

Apply the same `_swipeDirections` / `swipeDirections` / `swipeInDirection` additions to `MockCompanionClient` in `Tests/AndroidDriverTests/AndroidDriverTests.swift`, then add equivalent tests:
```swift
    func testSwipeDirectionDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = AndroidDriver(companion: companion)
        try await driver.swipe(direction: .up, distance: 250, duration: Duration(milliseconds: 350))
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .up)
        XCTAssertNil(swipes[0].element)
    }
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
swift test --filter IOSDriverTests/testSwipeDirectionDelegatesToCompanion 2>&1 | tail -5
```
Expected: Compiler error or test failure — `swipe(direction:distance:duration:)` is not implemented.

- [ ] **Step 3: Implement in `IOSDriver`**

In `Sources/IOSDriver/IOSDriver.swift`, in the Gesture Actions section, add:
```swift
    public func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: nil)
    }

    public func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: element)
    }
```

- [ ] **Step 4: Implement in `AndroidDriver`**

In `Sources/AndroidDriver/AndroidDriver.swift`, in the Gesture Actions section, add:
```swift
    public func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: nil)
    }

    public func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws {
        try await companion.swipeInDirection(direction, distance: distance, duration: duration, element: element)
    }
```

- [ ] **Step 5: Run tests**

```bash
swift test --filter IOSDriverTests 2>&1 | tail -10
swift test --filter AndroidDriverTests 2>&1 | tail -10
```
Expected: All pass.

- [ ] **Step 6: Run full suite**

```bash
swift test 2>&1 | tail -5
```
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/IOSDriver/IOSDriver.swift \
        Sources/AndroidDriver/AndroidDriver.swift \
        Tests/IOSDriverTests/IOSDriverTests.swift \
        Tests/AndroidDriverTests/AndroidDriverTests.swift
git commit -m "feat: implement swipe(direction:) and swipe(direction:element:) in iOS and Android drivers"
```

---

### Task 7: MCP — ActionTools + ToolExecutor (TDD)

**Files:**
- Modify: `Sources/MCPServer/Tools/ActionTools.swift`
- Modify: `Sources/MCPServer/ToolExecutor.swift`
- Test: `Tests/MCPServerTests/MCPServerTests.swift`

- [ ] **Step 1: Write failing test**

In `MCPServerTests.swift`, add:

```swift
    func testSwipeInDirectionTool() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        // Screen-center directional swipe
        let result = await server.execute(
            toolName: "swipe_in_direction",
            arguments: ["direction": "left", "distance": "300", "duration_ms": "400"]
        )
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("left"))

        // Swipe with element
        let resultWithElement = await server.execute(
            toolName: "swipe_in_direction",
            arguments: [
                "direction": "up",
                "element_id": "scroll-view"
            ]
        )
        XCTAssertFalse(resultWithElement.isError)

        // Missing direction should error
        let missing = await server.execute(
            toolName: "swipe_in_direction",
            arguments: [:]
        )
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(missing.content.contains("direction"))

        let calls = await driver.calls
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:left") }))
        XCTAssertTrue(calls.contains(where: { $0.hasPrefix("swipeInDirection:up") }))
    }

    func testSwipeInDirectionToolNameExposed() {
        let server = MCPServer()
        XCTAssertTrue(server.toolNames().contains("swipe_in_direction"))
    }
```

Also update `MockDriver` — replace the existing `swipe(direction:)` method (1-param, dead code) with the protocol-matching signature:
```swift
    func swipe(direction: Direction, distance: Double, duration: Duration) async throws {
        calls.append("swipeInDirection:\(direction):\(distance)")
    }

    func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws {
        let suffix = element.flatMap { $0.id }.map { ":\($0)" } ?? ""
        calls.append("swipeInDirection:\(direction):\(distance)\(suffix)")
    }
```

Do the same for the second `MockDriver` instance further down in the file (the one with `calls.append("swipeDir")`).

- [ ] **Step 2: Run test to confirm it fails**

```bash
swift test --filter MCPServerTests/testSwipeInDirectionTool 2>&1 | tail -5
```
Expected: Compiler error or test failure — `swipe_in_direction` tool not found.

- [ ] **Step 3: Add `swipe_in_direction` tool definition to `ActionTools.swift`**

In `Sources/MCPServer/Tools/ActionTools.swift`, add after the `swipe` tool definition:
```swift
        ToolDefinition(
            name: "swipe_in_direction",
            description: "Swipe in a direction from screen center or a specific element",
            properties: [
                "direction": .init(type: "string", description: "Swipe direction: up, down, left, or right"),
                "distance": .init(type: "string", description: "Swipe distance in points. Defaults to 300."),
                "duration_ms": .init(type: "string", description: "Swipe duration in milliseconds. Defaults to 400."),
                "element_id": .init(type: "string", description: "Accessibility ID of element to swipe on. Omit for screen-center swipe."),
                "element_label": .init(type: "string", description: "Accessibility label of element to swipe on.")
            ],
            required: ["direction"]
        ),
```

- [ ] **Step 4: Add case to `ToolExecutor.dispatch`**

In `Sources/MCPServer/ToolExecutor.swift`, add after the `"swipe":` case:
```swift
        case "swipe_in_direction":
            guard let dirStr = arguments["direction"] else {
                return .error("Missing required argument: direction (up|down|left|right)")
            }
            guard let direction = parseDirection(dirStr) else {
                return .error("Invalid direction: \(dirStr). Use up, down, left, or right.")
            }
            let distance = arguments["distance"].flatMap(Double.init) ?? 300
            let ms = arguments["duration_ms"].flatMap(Int.init) ?? 400
            let element: ElementSelector? = if let id = arguments["element_id"] {
                ElementSelector(id: id)
            } else if let label = arguments["element_label"] {
                ElementSelector(label: label)
            } else {
                nil
            }
            try await driver.swipe(
                direction: direction,
                distance: distance,
                duration: Duration(milliseconds: ms),
                element: element
            )
            return .success("Swiped \(dirStr) by \(distance) pts")
```

- [ ] **Step 5: Run tests**

```bash
swift test --filter MCPServerTests 2>&1 | tail -10
```
Expected: All pass.

- [ ] **Step 6: Run full suite**

```bash
swift test 2>&1 | tail -5
```
Expected: All 54+ tests pass, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/MCPServer/Tools/ActionTools.swift \
        Sources/MCPServer/ToolExecutor.swift \
        Tests/MCPServerTests/MCPServerTests.swift
git commit -m "feat: add swipe_in_direction MCP tool wired to driver swipe(direction:)"
```
