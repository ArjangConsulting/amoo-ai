# Architecture

## Design Principles

1. **Protocol boundaries** — Every module exposes a protocol (Swift `protocol`). Consumers depend on protocols, not concrete implementations.
2. **Dependency inversion** — High-level modules (CLI, orchestrator, AI) depend on abstractions. Low-level modules (simctl/adb wrappers, companion clients) implement them.
3. **Intent-level parity with capabilities** — Shared APIs represent test intent (`tap`, `type`, `waitForElement`, `goBack`). Unsupported platform behavior is explicit through capabilities and typed errors.
4. **AI-first data model** — View hierarchy, element descriptors, and screen context are structured for LLM consumption (token-efficient, semantic, deterministic first).
5. **Clear host/device split** — Host owns lifecycle/orchestration/policy; companion owns UI interaction/accessibility/screen context on-device.
6. **gRPC contract-first** — Host-to-companion communication uses gRPC. Proto files are the source of truth for Swift and Kotlin codegen.
7. **Versioned contracts** — Swift public protocols, proto contracts, and MCP tool schemas follow semantic versioning and compatibility rules.
8. **Quality gates by default** — Lint, formatting, tests, and coverage thresholds are enforced in CI for every PR.

---

## Module Map

```
amoo/
├── Package.swift
│
├── .github/
│   └── workflows/
│       ├── ci.yml                         # Lint + test + coverage gates on PR/push
│       └── release.yml                    # Tag-triggered release workflow
│
├── Protos/                              # gRPC/Protobuf definitions
│   ├── actions.proto                    #   Shared action definitions
│   ├── device.proto                     #   Device lifecycle & info
│   ├── accessibility.proto              #   View hierarchy & elements
│   └── ai.proto                         #   AI-specific queries
│
├── Sources/
│   ├── AmooCore/               # Module 1: Shared protocols & types
│   │   ├── Actions/
│   │   │   ├── TouchActions.swift       #   Tap, long press, double tap
│   │   │   ├── GestureActions.swift     #   Swipe, scroll, pinch, drag
│   │   │   ├── TextActions.swift        #   Type, clear, set text
│   │   │   ├── NavigationActions.swift  #   Back, home, app switch
│   │   │   └── Actions.swift            #   Unified protocol composing all action groups
│   │   ├── Device/
│   │   │   ├── DeviceDriver.swift       #   Device lifecycle protocol
│   │   │   ├── DeviceInfo.swift         #   Device metadata types
│   │   │   └── AppManagement.swift      #   Install, launch, terminate, uninstall
│   │   ├── Capture/
│   │   │   ├── ScreenCapture.swift      #   Screenshot protocol
│   │   │   └── VideoRecording.swift     #   Video recording protocol
│   │   ├── Accessibility/
│   │   │   ├── ViewHierarchy.swift      #   Tree structure for UI elements
│   │   │   ├── ElementQuery.swift       #   Find elements by various selectors
│   │   │   └── ElementInfo.swift        #   Element properties (label, type, frame, etc.)
│   │   ├── Configuration/
│   │   │   ├── Permissions.swift        #   Grant/revoke/reset permissions
│   │   │   ├── Location.swift           #   Location simulation
│   │   │   └── DeviceSettings.swift     #   Appearance, locale, content size
│   │   ├── AI/
│   │   │   ├── ScreenContext.swift       #   AI-optimized screen description
│   │   │   └── SemanticQuery.swift       #   Find element by natural language
│   │   ├── Errors.swift                 #   Shared error types
│   │   └── Types.swift                  #   Point, Size, Rect, Duration, etc.
│   │
│   ├── CompanionProtocol/               # Module 2: Companion app contract
│   │   ├── CompanionClient.swift        #   Protocol for talking to companion
│   │   ├── CompanionConnection.swift    #   Connection lifecycle (connect, health, disconnect)
│   │   └── GRPCCompanionClient.swift    #   gRPC implementation of CompanionClient
│   │
│   ├── IOSDriver/                       # Module 3: iOS platform driver
│   │   ├── IOSDriver.swift              #   Implements DeviceDriver + Actions (delegates to companion)
│   │   ├── IOSDeviceControl.swift       #   Boot, shutdown, install via simctl/devicectl
│   │   ├── IOSScreenCapture.swift       #   Screenshot/video via simctl
│   │   ├── SimctlRunner.swift           #   xcrun simctl wrapper (internal, replaceable)
│   │   └── DevicectlRunner.swift        #   devicectl wrapper for real devices (internal)
│   │
│   ├── AndroidDriver/                   # Module 4: Android platform driver
│   │   ├── AndroidDriver.swift          #   Implements DeviceDriver + Actions (delegates to companion)
│   │   ├── AndroidDeviceControl.swift   #   Boot, shutdown, install via adb
│   │   ├── AndroidScreenCapture.swift   #   Screenshot/video via adb
│   │   └── ADBRunner.swift              #   adb wrapper (internal, replaceable)
│   │
│   ├── ProcessRunner/                   # Module 5: Shell command execution
│   │   ├── ProcessRunner.swift          #   Protocol for running external processes
│   │   └── SystemProcessRunner.swift    #   Foundation.Process implementation
│   │
│   ├── GRPCService/                     # Module 6: gRPC server (exposes drivers to external tools)
│   │   ├── DeviceService.swift          #   gRPC service implementation
│   │   └── ServiceConfig.swift          #   Server configuration
│   │
│   ├── MCPServer/                       # Module 7: MCP server (exposes drivers as AI tools)
│   │   ├── MCPServer.swift              #   MCP protocol implementation
│   │   └── Tools/                       #   MCP tool definitions
│   │       ├── DeviceTools.swift
│   │       ├── ActionTools.swift
│   │       └── QueryTools.swift
│   │
│   ├── AuditEngine/                     # Module 8: Rule-based audit engine
│   │   ├── AuditEngine.swift            #   Orchestrates rule execution
│   │   ├── AuditRule.swift              #   Rule protocol + metadata
│   │   ├── AuditEvidence.swift          #   Evidence model (selector, screenshot, logs)
│   │   ├── AuditFinding.swift           #   Severity/confidence/remediation model
│   │   ├── AuditReport.swift            #   JSON + markdown output schema
│   │   └── RulePacks/
│   │       ├── SecurityRules.swift      #   MASVS-aligned heuristics
│   │       ├── QualityRules.swift       #   Stability/reliability checks
│   │       ├── UXRules.swift            #   UX and accessibility heuristics
│   │       └── TestabilityRules.swift   #   Selector/test authoring guidance
│   │
│   └── CLI/                             # Module 9: Command-line interface + REPL
│       ├── CLI.swift                    #   Entry point
│       ├── Commands/
│       │   ├── RunCommand.swift         #   Run test flows
│       │   ├── DeviceCommand.swift      #   Device management
│       │   ├── AuditCommand.swift       #   App auditing
│       │   └── REPLCommand.swift        #   Interactive mode
│       └── Output/
│           └── Formatter.swift          #   Output formatting
│
├── scripts/
│   └── ci/
│       ├── lint.sh                       # swiftformat --lint + swiftlint --strict
│       ├── format.sh                     # Auto-format local changes
│       └── test_coverage.sh              # Enforce per-module + repo coverage gates
│
├── CompanionApps/
│   ├── iOS/                             # Module 10: iOS companion app (Xcode project)
│   │   └── AmooCompanion/
│   │       ├── AmooCompanionUITests/
│   │       │   ├── CompanionServer.swift      # gRPC server running inside XCUITest
│   │       │   ├── Handlers/
│   │       │   │   ├── TouchHandler.swift     # Tap, long press, double tap
│   │       │   │   ├── GestureHandler.swift   # Swipe, scroll, pinch
│   │       │   │   ├── TextHandler.swift      # Text input, clear
│   │       │   │   ├── HierarchyHandler.swift # View hierarchy extraction
│   │       │   │   ├── QueryHandler.swift     # Element finding
│   │       │   │   └── AIHandler.swift        # AI-optimized screen context
│   │       │   └── XCUITestBridge.swift        # Translates commands to XCUITest API calls
│   │       └── AmooCompanion.xcodeproj
│   │
│   └── Android/                         # Module 11: Android companion app (Gradle project)
│       └── companion-app/
│           ├── app/src/androidTest/
│           │   ├── CompanionServer.kt         # gRPC server running inside instrumentation
│           │   ├── handlers/
│           │   │   ├── TouchHandler.kt
│           │   │   ├── GestureHandler.kt
│           │   │   ├── TextHandler.kt
│           │   │   ├── HierarchyHandler.kt
│           │   │   ├── QueryHandler.kt
│           │   │   └── AIHandler.kt
│           │   └── UIAutomatorBridge.kt       # Translates commands to UIAutomator2 API calls
│           ├── build.gradle.kts
│           └── settings.gradle.kts
│
└── Tests/
    ├── AmooCoreTests/
    ├── IOSDriverTests/
    ├── AndroidDriverTests/
    ├── CompanionProtocolTests/
    ├── AuditEngineTests/
    └── ProcessRunnerTests/
```

---

## Capability Model

Capabilities are runtime-discovered and determine which actions are safe to call on a session.

- `required` capabilities must exist on iOS and Android.
- `optional` capabilities may vary by platform, OS version, or device type.
- `unsupported` capabilities must return typed errors with remediation hints.

```swift
public enum CapabilityTier: Sendable {
    case required
    case optional
}

public struct CapabilityDescriptor: Sendable {
    public var key: String
    public var tier: CapabilityTier
    public var supported: Bool
    public var reasonIfUnsupported: String?
}
```

Examples:

- `action.tap`, `action.typeText`, `query.findElements`, `query.waitForElement` are `required`.
- `action.openNotifications`, `action.pressAppSwitch`, `action.clearAppData` are `optional`.
- Host-side lifecycle operations (`installApp`, `launchApp`, `setPermission`) are not companion capabilities.

---

## Protocol Hierarchy

The key insight: **Actions are composed from small, focused protocols.** Each one is independently mockable and testable. A platform can declare which capabilities it supports.

```
                    ┌─────────────────┐
                    │   DeviceDriver   │  Device lifecycle + app management
                    └────────┬────────┘
                             │ has-a
                    ┌────────▼────────┐
                    │     Actions      │  Composed protocol (all action groups)
                    └────────┬────────┘
                             │ composes
        ┌──────────┬─────────┼──────────┬──────────────┐
        ▼          ▼         ▼          ▼              ▼
  TouchActions  GestureActions  TextActions  NavigationActions  ...
  - tap()       - swipe()       - typeText()  - back()
  - longPress() - scroll()      - clearText() - home()
  - doubleTap() - pinch()       - setText()   - appSwitch()
                - drag()
```

```
                    ┌─────────────────┐
                    │  ScreenCapture   │  Screenshot + video
                    └─────────────────┘

                    ┌─────────────────┐
                    │ AccessibilityProvider │  View hierarchy + element queries
                    └─────────────────┘

                    ┌─────────────────┐
                    │  DeviceConfigurator  │  Permissions, location, appearance
                    └─────────────────┘

                    ┌─────────────────┐
                    │  AIContextProvider   │  AI-optimized screen data
                    └─────────────────┘
```

### Composition at the driver level

```swift
/// The full driver combines all capabilities.
/// Each capability protocol can be implemented independently.
public protocol PlatformDriver:
    DeviceDriver,
    Actions,
    ScreenCapture,
    AccessibilityProvider,
    DeviceConfigurator,
    AIContextProvider,
    Sendable {}
```

iOS and Android each provide a `PlatformDriver` conformance. But internally, each capability is a separate component that can be swapped:

```swift
// IOSDriver delegates to internal components — all behind protocols
public final class IOSDriver: PlatformDriver {
    private let deviceControl: any DeviceControl        // SimctlRunner today, could be devicectl tomorrow
    private let companion: any CompanionClient           // gRPC client talking to on-device companion
    private let screenCapture: any ScreenCaptureProvider  // simctl io today, could be companion tomorrow

    // Touch actions delegate to companion
    public func tap(at point: Point) async throws {
        try await companion.tap(at: point)
    }

    // Device lifecycle delegates to deviceControl
    public func boot() async throws {
        try await deviceControl.boot()
    }

    // Screenshots delegate to screenCapture
    public func takeScreenshot() async throws -> ScreenshotData {
        try await screenCapture.takeScreenshot()
    }
}
```

If we later want to replace `simctl` with something else for device control, we swap `SimctlRunner` for a new conformance of `DeviceControl`. Nothing else changes.

---

## Actions — Full Feature Matrix

The contract is split by execution plane:

- **Core companion actions**: required across iOS/Android.
- **Optional companion actions**: capability-gated.
- **Host lifecycle/config actions**: executed by host tooling (`simctl`, `devicectl`, `adb`), not companion.

### Touch Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `tap` | Single tap | `point: Point` | |
| `doubleTap` | Double tap | `point: Point` | |
| `longPress` | Long press | `point: Point, duration: Duration` | |
| `tapElement` | Tap on element | `selector: ElementSelector` | Companion resolves selector to point |

### Gesture Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `swipe` | Swipe gesture | `from: Point, to: Point, duration: Duration` | |
| `swipeDirection` | Directional swipe | `direction: Direction, distance: Float, duration: Duration` | |
| `scroll` | Scroll in direction | `direction: Direction, distance: Float` | Distinct from swipe (inertia, behavior) |
| `scrollToElement` | Scroll until element visible | `selector: ElementSelector, direction: Direction, maxScrolls: Int` | |
| `pinch` | Pinch in/out | `center: Point, scale: Float, velocity: Float` | |
| `drag` | Drag from A to B | `from: Point, to: Point, duration: Duration, holdDuration: Duration` | Long press + move |

### Text Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `typeText` | Type text character by character | `text: String` | Simulates keyboard input |
| `setText` | Set text field value directly | `selector: ElementSelector, text: String` | Bypasses keyboard |
| `clearText` | Clear focused text field | `characterCount: Int?` | Delete N characters or all |
| `pasteText` | Paste from clipboard | `text: String` | Sets clipboard then pastes |

### Navigation Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `pressBack` | Back button/gesture | | Required intent; implementation differs by platform |
| `pressHome` | Home button/gesture | | Optional capability |
| `pressAppSwitch` | Recent apps | | Optional capability |
| `pressButton` | Hardware/soft button | `button: Button` | Optional capability (device/OS dependent) |
| `openUrl` | Open deep link / URL | `url: String` | Required |
| `openNotifications` | Open notification shade | | Optional capability |

### App Lifecycle Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `installApp` | Install app | `path: String` | Host-executed (`simctl`/`devicectl`/`adb`) |
| `launchApp` | Launch app | `appId: String, arguments: [String]?, env: [String:String]?` | Host-executed |
| `terminateApp` | Force stop app | `appId: String` | Host-executed |
| `uninstallApp` | Remove app | `appId: String` | Host-executed |
| `clearAppData` | Clear app storage | `appId: String` | Host-executed; optional on iOS |
| `listApps` | List installed apps | | Host-executed; returns `[AppInfo]` |
| `appState` | Get app state | `appId: String` | Host-executed |

### Screen Capture Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `takeScreenshot` | Capture screen | `format: ImageFormat` | PNG, JPEG |
| `startRecording` | Start video recording | `codec: VideoCodec?` | Returns `RecordingSession` |
| `stopRecording` | Stop video recording | `sessionId: String` | Returns video file path |

### Accessibility / View Hierarchy Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `getViewHierarchy` | Full UI tree | `appId: String?` | Returns `ViewNode` tree |
| `findElements` | Query elements | `selector: ElementSelector` | Returns `[ElementInfo]`. An empty selector returns unlabeled elements too, so a control with no id or label is still reachable by its frame; `selector.labeledOnly` drops them |
| `getElementInfo` | Single element details | `selector: ElementSelector` | Label, type, frame, value, traits |
| `elementExists` | Check existence | `selector: ElementSelector` | Returns `Bool` |
| `waitForElement` | Wait until visible | `selector: ElementSelector, timeout: Duration` | |
| `waitForElementToDisappear` | Wait until gone | `selector: ElementSelector, timeout: Duration` | |
| `isKeyboardVisible` | Keyboard state | | Returns `Bool` |

### Device Configuration Actions

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `setPermission` | Grant/revoke permission | `appId: String, permission: Permission, granted: Bool` | Host-executed |
| `resetPermissions` | Reset all permissions | `appId: String?` | Host-executed |
| `setLocation` | Simulate GPS | `latitude: Double, longitude: Double` | Host-executed |
| `clearLocation` | Stop simulating GPS | | Host-executed |
| `setAppearance` | Dark/light mode | `appearance: Appearance` | Host-executed |
| `setContentSize` | Dynamic type size | `size: ContentSize` | Host-executed; accessibility testing |
| `setLocale` | Change locale | `locale: String` | Host-executed |
| `setStatusBar` | Override status bar | `overrides: StatusBarOverrides` | Host-executed; clean screenshots |

### AI Context Actions (our differentiator)

| Action | Description | Parameters | Notes |
|--------|-------------|------------|-------|
| `getScreenContext` | AI-optimized screen summary | `format: ContextFormat` | Token-efficient representation |
| `describeScreen` | Natural language description | | Uses on-device processing |
| `findByDescription` | Find element by NL query | `description: String` | "the login button", "email field" |
| `suggestActions` | Suggest possible actions | | Based on current screen state |
| `getInteractableElements` | Only actionable elements | | Filters to buttons, fields, links |

---

## Element Selectors

Elements can be found by multiple strategies. The `ElementSelector` supports combining them:

```swift
public struct ElementSelector: Sendable {
    public var id: String?                    // Accessibility identifier
    public var label: String?                 // Accessibility label (visible text)
    public var type: ElementType?             // Button, TextField, StaticText, etc.
    public var value: String?                 // Current value
    public var index: Int?                    // Nth match
    public var containsText: String?          // Partial text match
    public var matchesPattern: String?        // Regex match
    public var description: String?           // Natural language (AI-resolved)
    public var parentSelector: ParentSelector?   // Scoped search
}

public indirect enum ParentSelector: Sendable {
    case selector(ElementSelector)
}
```

---

## Companion App Architecture

Both companions follow the same pattern: a long-running session on-device hosting a gRPC server with health checks, heartbeats, and graceful shutdown.

### iOS Companion

```
┌─────────────────────────────────────────────────┐
│  XCUITest Runner (session-managed)               │
│  ┌─────────────────────────────────────────────┐ │
│  │  gRPC Server (port 22087)                   │ │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ │ │
│  │  │  Touch    │ │  Gesture  │ │  Text     │ │ │
│  │  │  Handler  │ │  Handler  │ │  Handler  │ │ │
│  │  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ │ │
│  │        └──────────────┼──────────────┘       │ │
│  │                 ┌─────▼─────┐                │ │
│  │                 │ XCUITest  │                │ │
│  │                 │  Bridge   │                │ │
│  │                 └─────┬─────┘                │ │
│  │                       ▼                      │ │
│  │              XCUIApplication APIs            │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

- Runs as an XCUITest target (similar operational model to Maestro-style runners)
- Session lifecycle is explicit: start, heartbeat, idle-timeout, stop, reconnect
- Each handler translates gRPC requests into XCUITest API calls
- `XCUITestBridge` is the single point of contact with Apple's framework — if Apple changes APIs, only this file changes

### Android Companion

```
┌─────────────────────────────────────────────────┐
│  Instrumentation Test (session-managed)          │
│  ┌─────────────────────────────────────────────┐ │
│  │  gRPC Server (port 22088)                   │ │
│  │  ┌───────────┐ ┌───────────┐ ┌───────────┐ │ │
│  │  │  Touch    │ │  Gesture  │ │  Text     │ │ │
│  │  │  Handler  │ │  Handler  │ │  Handler  │ │ │
│  │  └─────┬─────┘ └─────┬─────┘ └─────┬─────┘ │ │
│  │        └──────────────┼──────────────┘       │ │
│  │                 ┌─────▼─────┐                │ │
│  │                 │UIAutomator│                │ │
│  │                 │  Bridge   │                │ │
│  │                 └─────┬─────┘                │ │
│  │                       ▼                      │ │
│  │            UIAutomator2 / UiDevice APIs      │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

- Runs as an Android instrumentation test with the same session lifecycle model
- Same handler structure as iOS — same proto contract
- `UIAutomatorBridge` isolates UIAutomator2 APIs — replaceable with Espresso or other frameworks

### Communication Flow

```
Host (Swift CLI/gRPC/MCP)
    │
    ▼
PlatformDriver (IOSDriver or AndroidDriver)
    │
    ├── Device lifecycle ──► simctl / adb (via ProcessRunner protocol)
    │
    └── UI actions ──► CompanionClient protocol
                            │
                            ▼
                       gRPC connection
                            │
                            ▼
                    Companion App (on device)
                            │
                            ▼
                    Platform Bridge (XCUITest / UIAutomator2)
```

---

## Modularity Boundaries

Each arrow below represents a protocol boundary. Anything behind the protocol can be replaced.

```
CLI ──► PlatformDriver protocol
             │
             ├──► DeviceControl protocol ──► SimctlRunner (swappable)
             │                                ADBRunner (swappable)
             │
             ├──► CompanionClient protocol ──► GRPCCompanionClient (swappable)
             │                                  Alternate transports are future-major options
             │
             ├──► ScreenCaptureProvider protocol ──► SimctlCapture (swappable)
             │                                       CompanionCapture (swappable)
             │
             └──► ProcessRunner protocol ──► SystemProcessRunner (swappable)
                                              MockProcessRunner (for tests)
```

### What "swappable" means concretely

**Today**: `IOSDeviceControl` uses `SimctlRunner` to call `xcrun simctl boot`.
**Tomorrow**: Apple ships a new tool. We write `NewToolRunner` conforming to the same `DeviceControl` protocol. Change one line in `IOSDriver` init. Nothing else is affected.

**Today**: Companion uses gRPC over `GRPCCompanionClient`.
**Tomorrow**: We want WebSockets. Write `WebSocketCompanionClient` conforming to `CompanionClient`. Swap at init. Drivers, CLI, MCP — all unchanged.

---

## Proto Contract (Companion ↔ Host)

The `.proto` files define the contract between host drivers and companion apps. Both iOS (Swift) and Android (Kotlin) companions implement the same service surface for companion-owned actions.

```protobuf
// Simplified — full definitions in Protos/

service CompanionService {
  // Session + capability negotiation
  rpc StartSession (StartSessionRequest) returns (StartSessionResponse);
  rpc GetCapabilities (CapabilitiesRequest) returns (CapabilitiesResponse);
  rpc EndSession (EndSessionRequest) returns (EndSessionResponse);

  // Touch
  rpc Tap (TapRequest) returns (ActionResponse);
  rpc DoubleTap (TapRequest) returns (ActionResponse);
  rpc LongPress (LongPressRequest) returns (ActionResponse);

  // Gestures
  rpc Swipe (SwipeRequest) returns (ActionResponse);
  rpc Scroll (ScrollRequest) returns (ActionResponse);
  rpc Pinch (PinchRequest) returns (ActionResponse);

  // Text
  rpc TypeText (TypeTextRequest) returns (ActionResponse);
  rpc ClearText (ClearTextRequest) returns (ActionResponse);

  // Navigation
  rpc PressButton (PressButtonRequest) returns (ActionResponse);

  // Accessibility
  rpc GetViewHierarchy (ViewHierarchyRequest) returns (ViewHierarchyResponse);
  rpc FindElements (FindElementsRequest) returns (FindElementsResponse);
  rpc WaitForElement (WaitForElementRequest) returns (WaitForElementResponse);

  // Capture
  rpc TakeScreenshot (ScreenshotRequest) returns (ScreenshotResponse);

  // Device info
  rpc GetDeviceInfo (DeviceInfoRequest) returns (DeviceInfoResponse);
  rpc IsKeyboardVisible (Empty) returns (KeyboardVisibleResponse);

  // AI Context
  rpc GetScreenContext (ScreenContextRequest) returns (ScreenContextResponse);
  rpc FindByDescription (FindByDescriptionRequest) returns (FindElementsResponse);
  rpc GetInteractableElements (Empty) returns (FindElementsResponse);
}
```

Host-owned operations (install/uninstall/launch/terminate/permissions/location/device settings) live in host driver protocols and host services, not companion service RPCs.

### Contract versioning rules

- SemVer is required for proto schema, Swift public APIs, and MCP tool schemas.
- Additive changes are backward compatible.
- Breaking changes require a major version and a migration note.
- Companion and host must perform version compatibility checks on session start.

### Security and policy requirements

- Companion endpoints are local-only by default and accessed via explicit forwarding/tunneling.
- Session authentication is required for remote or shared environments.
- Every action is logged with correlation IDs and redacted payload fields.
- Authorization policies can deny high-risk actions (`uninstallApp`, destructive settings changes) by environment.

---

## What Lives Where

| Concern | Runs on Host (Mac) | Runs on Device |
|---------|-------------------|----------------|
| Device boot/shutdown | simctl / adb | — |
| App install/uninstall | simctl / adb | — |
| App launch/terminate | simctl / adb | — |
| Port forwarding | adb forward | — |
| Capability negotiation | Driver + companion client | Companion service response |
| Tap, swipe, type | — | Companion (XCUITest / UIAutomator2) |
| View hierarchy | — | Companion |
| Element queries | — | Companion |
| Screenshot | simctl / adb OR companion | Optional |
| Video recording | simctl / adb | — |
| AI screen context | — | Companion |
| Permissions | simctl / adb | — |
| Location simulation | simctl / adb | — |
| Appearance/settings | simctl / adb | — |
| Audit orchestration + report generation | CLI / MCP / Audit engine | Companion provides evidence context |

---

## Audit Engine Architecture

`AuditEngine` is a deterministic rule engine that consumes runtime evidence and produces reproducible findings.

### Rule contract

```swift
public enum AuditDomain: String, Sendable {
    case security
    case quality
    case ux
    case testability
}

public enum Severity: String, Sendable {
    case critical
    case high
    case medium
    case low
    case info
}

public struct AuditRuleMetadata: Sendable {
    public var id: String                  // e.g. SEC-001
    public var title: String
    public var domain: AuditDomain
    public var defaultSeverity: Severity
    public var references: [String]        // OWASP MASVS/MSTG, internal docs
}

public protocol AuditRule: Sendable {
    var metadata: AuditRuleMetadata { get }
    func evaluate(_ input: AuditInput) async throws -> [AuditFinding]
}
```

### Evidence model

All findings require evidence payloads for traceability:

```swift
public struct AuditEvidence: Sendable {
    public var kind: EvidenceKind          // hierarchy, selector, screenshot, log, config, trace
    public var summary: String
    public var sourceRef: String           // file path, action id, element id, session id
    public var attributes: [String: String]
}
```

Evidence sources:

- static app/runtime configuration (plist, manifest, launch config, permission state)
- dynamic UI state (view hierarchy snapshots, selector matches, interaction traces)
- artifacts (screenshots, video references, structured logs)

### Finding model

```swift
public struct AuditFinding: Sendable {
    public var id: String
    public var ruleId: String
    public var severity: Severity
    public var confidence: Double          // 0.0 ... 1.0
    public var summary: String
    public var remediation: String
    public var evidence: [AuditEvidence]
    public var tags: [String]              // security, auth, accessibility, flakiness
}
```

Scoring policy:

- severity comes from rule metadata with rule-time overrides.
- confidence is mandatory and evidence-based.
- findings with confidence below policy threshold are emitted as `info` unless `--allow-low-confidence` is set.

### Rule packs (v1)

- `SecurityRules`: OWASP MASVS-aligned heuristics (transport config, debug exposure, insecure storage indicators, deep-link hardening checks).
- `QualityRules`: crash-prone flow detection, error-state handling gaps, retry/timeout anti-patterns.
- `UXRules`: accessibility labels/traits, navigation dead-ends, weak feedback states.
- `TestabilityRules`: unstable selectors, missing identifiers, flaky interaction hotspots.

### Execution flow

1. CLI/MCP `audit` command resolves app target + policy profile.
2. Host driver performs preflight and lifecycle setup.
3. Companion collects dynamic context (hierarchy, interactables, screen context).
4. Audit engine runs selected rule packs in parallel-safe groups.
5. Findings are deduplicated, scored, policy-filtered, and sorted.
6. Reports are written as JSON + markdown; optional SARIF export can be added.

### Output contract

Report formats:

- machine-readable JSON (`AuditReport`).
- human-readable markdown summary for PRs/issues.

Every report includes:

- environment metadata (platform, OS, simulator/emulator/device, app id/build).
- policy metadata (enabled rule packs, thresholds, exclusions).
- finding list with severity/confidence/evidence/remediation.
- execution summary (duration, actions executed, artifact references).

### CI integration requirements

- `audit` can run headless in CI with deterministic exit codes.
- policy can fail builds by severity threshold (for example: fail on `high`+).
- reports are uploaded as workflow artifacts and linked in job summaries.

---

## Testing Strategy

Every protocol boundary is a mocking point:

```swift
// Mock the companion for driver tests (no real device needed)
final class MockCompanionClient: CompanionClient {
    var tapCalls: [Point] = []
    func tap(at point: Point) async throws { tapCalls.append(point) }
    // ...
}

// Mock the process runner for simctl/adb tests (no shell needed)
final class MockProcessRunner: ProcessRunner {
    var results: [String: ProcessResult] = [:]
    func run(_ arguments: String...) async throws -> ProcessResult {
        // return pre-configured result
    }
}

// Mock the full driver for CLI/orchestrator tests
struct MockPlatformDriver: PlatformDriver {
    // ...
}
```

CI quality gates are mandatory:

- `swiftformat --lint` must pass.
- `swiftlint --strict` must pass.
- `AmooCore` line coverage >= 85%.
- Driver/protocol modules line coverage >= 75%.
- Repo-wide line coverage >= 80% before `v1.0.0`.
- PRs cannot reduce coverage by more than 1% without explicit reviewer approval.

---

## Build Phases (Revised)

| Phase | Deliverable | Language | Depends On |
|-------|------------|----------|------------|
| 0 | Repo foundation (git, lint/format, CI workflows, coverage gate scripts) | YAML/Bash | — |
| 1 | Swift package + core protocols + types | Swift | Phase 0 |
| 2 | Proto files + codegen setup + version policy checks | Protobuf/Swift | Phase 1 |
| 3 | ProcessRunner + SimctlRunner + ADBRunner | Swift | Phase 1 |
| 4 | iOS companion app (XCUITest bridge + gRPC server + session lifecycle) | Swift | Phase 2 |
| 5 | Android companion app (UIAutomator bridge + gRPC server + session lifecycle) | Kotlin | Phase 2 |
| 6 | IOSDriver (host lifecycle + companion actions + capability checks) | Swift | Phase 3, 4 |
| 7 | AndroidDriver (host lifecycle + companion actions + capability checks) | Swift | Phase 3, 5 |
| 8 | AuditEngine target + v1 rule packs + report schema | Swift | Phase 6, 7 |
| 9 | CLI + REPL + preflight environment checks + audit command | Swift | Phase 8 |
| 10 | gRPC host service layer + audit report APIs | Swift | Phase 9 |
| 11 | MCP stdio server + assistant-facing tools for local AI clients | Swift | Phase 10 |
