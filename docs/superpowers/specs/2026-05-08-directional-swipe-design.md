# Directional Swipe Support

**Date:** 2026-05-08  
**Status:** Approved

## Problem

`SwipeRequest` only accepts coordinate pairs (`from`/`to`). The `swipe(direction:distance:duration:)` method in the `GestureActions` Swift protocol exists but throws `.notImplemented` everywhere. There is no way to call `swipe(.left)` without computing screen coordinates manually.

`scroll` already supports directions but carries scroll semantics (slow, inertia). Swipe is a distinct gesture (fast flick, used for dismissal/navigation), and both platforms expose dedicated directional swipe APIs.

## Goal

Add a direction-based swipe API that:
- Supports up, down, left, right
- Defaults to screen center when no element is specified
- Accepts an optional `ElementSelector` to swipe on a specific element
- Works identically on iOS and Android
- Is purely additive — no changes to the existing coordinate `Swipe` RPC

## Approach: New `SwipeInDirection` RPC

Add alongside the existing `Swipe` RPC. The existing `swipe(direction:distance:duration:)` Swift protocol stub gets wired up end-to-end.

## Proto Changes

File: `Protos/actions.proto` (and Android symlink at `CompanionApps/Android/app/src/main/proto/actions.proto`)

```protobuf
message SwipeDirectionRequest {
  Direction direction = 1;
  float distance = 2;       // points; 0 = platform default (~300)
  int32 duration_ms = 3;    // 0 = platform default
  ElementSelector selector = 4;  // optional; absent = screen center
}

rpc SwipeInDirection (SwipeDirectionRequest) returns (ActionResponse);
```

`distance = 0` and `duration_ms = 0` mean "use platform default" — platforms apply sensible defaults (~300 pts distance, ~400 ms).

## iOS Companion

**`XCUITestBridge`** gains:
```swift
func swipeInDirection(_ direction: SwipeDirection, distance: Double, durationMs: Int, element: ElementQuery?)
```
- No element → calls `app.swipeLeft()` / `.swipeRight()` / `.swipeUp()` / `.swipeDown()` (XCUITest native)
- With element → resolves element via existing query logic, calls same methods on the `XCUIElement`
- `distance` and `durationMs` are passed as velocity when non-zero; zero uses XCUITest defaults

**`GestureHandler`** gains a matching delegation method.  
**`CompanionServiceProvider`** maps `SwipeDirectionRequest` fields and calls `GestureHandler`.

## Android Companion

**`UIAutomatorBridge`** gains:
```kotlin
fun swipeInDirection(direction: Direction, distance: Int, durationMs: Int, selector: UiSelector?): Boolean
```
- No element → computes target from screen center + direction + distance, calls `device.swipe(cx, cy, tx, ty, steps)`
- With element → resolves via `UiSelector`, gets bounds centroid, calls `UiObject2.swipe(direction, percent, speed)`
- `steps` computed from `durationMs / 5` (same as existing `GestureHandler.swipe`)

**`GestureHandler`** gains a matching delegation method.  
**`CompanionServiceImpl`** maps `SwipeDirectionRequest` and calls `GestureHandler`.

## Host-Side Wiring

**`CompanionClient` protocol** gains:
```swift
func swipeInDirection(_ direction: Direction, distance: Double, duration: Duration, element: ElementSelector?) async throws
```

**`GRPCCompanionClient`** implements it by sending `SwipeDirectionRequest`.

**`IOSDriver`** and **`AndroidDriver`** implement the previously-stubbed `GestureActions` method:
```swift
func swipe(direction: Direction, distance: Double, duration: Duration) async throws
// delegates to companion.swipeInDirection(..., element: nil)
```

Element-targeted variant is a separate method added to both drivers:
```swift
func swipe(direction: Direction, distance: Double, duration: Duration, element: ElementSelector) async throws
```

## MCP Tool

New tool `swipe_in_direction` in `ActionTools.swift`:

| Parameter | Type | Required | Description |
|---|---|---|---|
| `device_id` | string | yes | Target device |
| `direction` | string | yes | `up`, `down`, `left`, `right` |
| `distance` | string | no | Points (default ~300) |
| `duration_ms` | string | no | Milliseconds (default ~400) |
| `element_selector` | object | no | ElementSelector JSON; absent = screen center |

## Changes Summary

| File | Change |
|---|---|
| `Protos/actions.proto` | Add `SwipeDirectionRequest` message + `SwipeInDirection` RPC |
| `CompanionApps/Android/.../actions.proto` | Same (symlink or copy) |
| `CompanionApps/iOS/GeneratedProtos/` | Regenerate after proto change |
| `CompanionApps/iOS/.../XCUITestBridge.swift` | Add `swipeInDirection` |
| `CompanionApps/iOS/.../GestureHandler.swift` | Add delegation method |
| `CompanionApps/iOS/.../CompanionServiceProvider.swift` | Map + call new RPC |
| `CompanionApps/Android/.../UIAutomatorBridge.kt` | Add `swipeInDirection` |
| `CompanionApps/Android/.../GestureHandler.kt` | Add delegation method |
| `CompanionApps/Android/.../CompanionServiceImpl.kt` | Map + call new RPC |
| `Sources/CompanionProtocol/CompanionClient.swift` | Add `swipeInDirection` to protocol |
| `Sources/CompanionProtocol/GRPCCompanionClient.swift` | Implement gRPC call |
| `Sources/IOSDriver/IOSDriver.swift` | Implement `swipe(direction:)` |
| `Sources/AndroidDriver/AndroidDriver.swift` | Implement `swipe(direction:)` |
| `Sources/MCPServer/Tools/ActionTools.swift` | Add `swipe_in_direction` tool |
| `Sources/MCPServer/ToolExecutor.swift` | Handle new tool case |
| Tests | Unit tests for new method in each module |

## Out of Scope

- Swipe velocity curve customization (beyond duration/distance)
- Multi-finger swipe
- Scroll-to-end via repeated directional swipe (use `scrollToElement` instead)
