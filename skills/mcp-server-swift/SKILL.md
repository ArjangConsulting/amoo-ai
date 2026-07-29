---
name: mcp-server-swift
description: Guide for building MCP (Model Context Protocol) servers in Swift — tool definitions, resource providers, prompt templates, transports (stdio/HTTP), and integration with AI agents like Claude Code.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-07-29 |
| MCP Spec | 2026-07-28 (dual-era with 2025-11-25) |
| Swift MCP SDK | 0.12.1 (`modelcontextprotocol/swift-sdk`) |
| Swift | 6.0+ |
| Platforms | macOS 13+, iOS 16+, Linux |
| Source | [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk), [MCP spec](https://modelcontextprotocol.io/specification/2026-07-28) |

> The official Swift SDK's latest release is currently 0.12.1 and implements
> MCP 2025-11-25. Amoo implements the 2026-07-28 stateless stdio wire boundary
> directly while retaining the SDK for shared MCP value and tool types.

### Update checklist
- [ ] Check [swift-sdk releases](https://github.com/modelcontextprotocol/swift-sdk/releases) for new versions
- [ ] Check [MCP spec changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog) for protocol changes
- [ ] Review [MCP roadmap](https://modelcontextprotocol.io/development/roadmap.md) for upcoming features
- [ ] Check if new transport types have been added
- [ ] Verify tool/resource/prompt API signatures haven't changed
- [ ] Review [MCP Registry](https://modelcontextprotocol.io/registry/about.md) for publishing updates

# MCP Server Swift Skill

Guide for building MCP servers in Swift that expose mobile testing capabilities (device actions, screenshots, accessibility tree, etc.) as tools, resources, and prompts for AI agents.

## When to use

Use this skill when:
- Building an MCP server that exposes mobile testing tools to AI agents
- Defining MCP tools with typed input schemas
- Serving device state and accessibility trees as MCP resources
- Creating prompt templates for common testing workflows
- Configuring stdio or HTTP transport for Claude Code integration

## Project Alignment (mobile-testing repo)

For this repository, follow these MCP server conventions:

- MCP tools must call `PlatformDriver` abstractions, never platform runners directly.
- Companion-only actions should check runtime capabilities before execution.
- Host lifecycle/config tools (`installApp`, `launchApp`, `setPermission`, etc.) run through host driver paths.
- Keep tool naming stable and action-oriented (`tap`, `find_elements`, `get_screen_context`, `run_audit`).
- Audit tooling should return structured findings with severity, confidence, remediation, and evidence references.

## MCP Core Concepts

### Architecture

```
AI Agent (Claude Code, Cursor, etc.)
    ↕ MCP Protocol (JSON-RPC over stdio or HTTP)
MCP Server (our Swift server)
    ↕ Internal calls
Device Drivers (simctl, adb, gRPC services)
```

### Three primitives

| Primitive | Direction | Purpose | Example |
|-----------|-----------|---------|---------|
| **Tools** | Agent → Server | Actions the agent can execute | `take_screenshot`, `tap`, `type_text` |
| **Resources** | Agent → Server | Data the agent can read | `device://booted/accessibility-tree`, `device://list` |
| **Prompts** | Agent → Server | Templated conversation starters | `test-flow`, `audit-app` |

### Capabilities

Servers declare what they support during initialization:

```swift
capabilities: .init(
    completions: .init(),          // autocomplete for prompt args
    logging: .init(),              // server can send log messages
    prompts: .init(listChanged: true),    // dynamic prompt list
    resources: .init(subscribe: true, listChanged: true),  // dynamic resources with subscriptions
    tools: .init(listChanged: true)       // dynamic tool list
)
```

## Package.swift Setup

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileTestingMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "MobileTestingMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
```

## Server Setup

### Basic server with stdio transport

```swift
import MCP

@main
struct MobileTestingServer {
    static func main() async throws {
        let server = Server(
            name: "mobile-testing",
            version: "1.0.0",
            capabilities: .init(
                logging: .init(),
                resources: .init(subscribe: true, listChanged: true),
                tools: .init(listChanged: true)
            )
        )

        // Register handlers (see sections below)
        await registerToolHandlers(server)
        await registerResourceHandlers(server)
        await registerPromptHandlers(server)

        // Start with stdio transport (for Claude Code integration)
        let transport = StdioTransport()
        try await server.start(transport: transport)
    }
}
```

### HTTP transport (for remote access)

```swift
import MCP

let server = Server(
    name: "mobile-testing",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: true))
)

// HTTP transport with SSE streaming
let transport = HTTPServerTransport(
    endpoint: URL(string: "http://localhost:8080")!,
    streaming: true
)
try await server.start(transport: transport)
```

## Defining Tools

Tools are the primary way AI agents interact with the testing framework.

### Tool list handler

```swift
func registerToolHandlers(_ server: Server) async {
    await server.withMethodHandler(ListTools.self) { params in
        let tools = [
            // Screenshot tool
            Tool(
                name: "take_screenshot",
                description: "Capture a screenshot of the device screen. Returns PNG image data.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object([
                            "type": "string",
                            "description": .string("Device UDID or serial. Use 'booted' for iOS or 'emulator-5554' for Android.")
                        ]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")]),
                            "description": .string("Target platform")
                        ]),
                        "format": .object([
                            "type": "string",
                            "enum": .array([.string("png"), .string("jpeg")]),
                            "default": .string("png"),
                            "description": .string("Image format")
                        ])
                    ]),
                    "required": .array([.string("device_id"), .string("platform")])
                ])
            ),

            // Tap tool
            Tool(
                name: "tap",
                description: "Tap at specific coordinates on the device screen.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object(["type": "string"]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")])
                        ]),
                        "x": .object([
                            "type": "integer",
                            "description": .string("X coordinate in screen pixels")
                        ]),
                        "y": .object([
                            "type": "integer",
                            "description": .string("Y coordinate in screen pixels")
                        ])
                    ]),
                    "required": .array([
                        .string("device_id"), .string("platform"),
                        .string("x"), .string("y")
                    ])
                ])
            ),

            // Type text tool
            Tool(
                name: "type_text",
                description: "Type text into the currently focused input field.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object(["type": "string"]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")])
                        ]),
                        "text": .object([
                            "type": "string",
                            "description": .string("Text to type")
                        ])
                    ]),
                    "required": .array([
                        .string("device_id"), .string("platform"), .string("text")
                    ])
                ])
            ),

            // Swipe tool
            Tool(
                name: "swipe",
                description: "Swipe from one point to another on the device screen.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object(["type": "string"]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")])
                        ]),
                        "start_x": .object(["type": "integer"]),
                        "start_y": .object(["type": "integer"]),
                        "end_x": .object(["type": "integer"]),
                        "end_y": .object(["type": "integer"]),
                        "duration_ms": .object([
                            "type": "integer",
                            "default": .int(300),
                            "description": .string("Swipe duration in milliseconds")
                        ])
                    ]),
                    "required": .array([
                        .string("device_id"), .string("platform"),
                        .string("start_x"), .string("start_y"),
                        .string("end_x"), .string("end_y")
                    ])
                ])
            ),

            // Get accessibility tree
            Tool(
                name: "get_accessibility_tree",
                description: "Get the accessibility tree of the current screen. Returns element hierarchy with labels, IDs, types, and bounds for AI-driven interaction planning.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object(["type": "string"]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")])
                        ])
                    ]),
                    "required": .array([.string("device_id"), .string("platform")])
                ])
            ),

            // Launch app
            Tool(
                name: "launch_app",
                description: "Launch an app on the device by bundle ID (iOS) or package name (Android).",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "device_id": .object(["type": "string"]),
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android")])
                        ]),
                        "app_id": .object([
                            "type": "string",
                            "description": .string("Bundle ID (iOS) or package name (Android)")
                        ])
                    ]),
                    "required": .array([
                        .string("device_id"), .string("platform"), .string("app_id")
                    ])
                ])
            ),

            // List devices
            Tool(
                name: "list_devices",
                description: "List all available simulators/emulators and connected devices.",
                inputSchema: .object([
                    "type": "object",
                    "properties": .object([
                        "platform": .object([
                            "type": "string",
                            "enum": .array([.string("ios"), .string("android"), .string("all")]),
                            "default": .string("all")
                        ]),
                        "state": .object([
                            "type": "string",
                            "enum": .array([.string("booted"), .string("shutdown"), .string("all")]),
                            "default": .string("all"),
                            "description": .string("Filter by device state")
                        ])
                    ])
                ])
            ),
        ]
        return .init(tools: tools)
    }
}
```

### Tool call handler

```swift
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "take_screenshot":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? "booted"
        let platform = params.arguments?["platform"]?.stringValue ?? "ios"
        let format = params.arguments?["format"]?.stringValue ?? "png"

        let screenshotData = try await captureScreenshot(
            deviceId: deviceId,
            platform: platform,
            format: format
        )

        // Return image content
        let base64 = screenshotData.base64EncodedString()
        let mimeType = format == "jpeg" ? "image/jpeg" : "image/png"
        return .init(
            content: [.image(base64, mimeType: mimeType)],
            isError: false
        )

    case "tap":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? ""
        let platform = params.arguments?["platform"]?.stringValue ?? ""
        let x = params.arguments?["x"]?.intValue ?? 0
        let y = params.arguments?["y"]?.intValue ?? 0

        try await performTap(deviceId: deviceId, platform: platform, x: x, y: y)
        return .init(
            content: [.text("Tapped at (\(x), \(y)) on \(deviceId)")],
            isError: false
        )

    case "type_text":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? ""
        let platform = params.arguments?["platform"]?.stringValue ?? ""
        let text = params.arguments?["text"]?.stringValue ?? ""

        try await performTypeText(deviceId: deviceId, platform: platform, text: text)
        return .init(
            content: [.text("Typed '\(text)' on \(deviceId)")],
            isError: false
        )

    case "get_accessibility_tree":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? ""
        let platform = params.arguments?["platform"]?.stringValue ?? ""

        let treeJSON = try await getAccessibilityTree(deviceId: deviceId, platform: platform)
        return .init(
            content: [.text(treeJSON)],
            isError: false
        )

    case "launch_app":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? ""
        let platform = params.arguments?["platform"]?.stringValue ?? ""
        let appId = params.arguments?["app_id"]?.stringValue ?? ""

        try await launchApp(deviceId: deviceId, platform: platform, appId: appId)
        return .init(
            content: [.text("Launched \(appId) on \(deviceId)")],
            isError: false
        )

    case "list_devices":
        let platform = params.arguments?["platform"]?.stringValue ?? "all"
        let state = params.arguments?["state"]?.stringValue ?? "all"

        let devicesJSON = try await listDevices(platform: platform, state: state)
        return .init(
            content: [.text(devicesJSON)],
            isError: false
        )

    case "swipe":
        let deviceId = params.arguments?["device_id"]?.stringValue ?? ""
        let platform = params.arguments?["platform"]?.stringValue ?? ""
        let startX = params.arguments?["start_x"]?.intValue ?? 0
        let startY = params.arguments?["start_y"]?.intValue ?? 0
        let endX = params.arguments?["end_x"]?.intValue ?? 0
        let endY = params.arguments?["end_y"]?.intValue ?? 0
        let duration = params.arguments?["duration_ms"]?.intValue ?? 300

        try await performSwipe(
            deviceId: deviceId, platform: platform,
            startX: startX, startY: startY,
            endX: endX, endY: endY,
            durationMs: duration
        )
        return .init(
            content: [.text("Swiped from (\(startX),\(startY)) to (\(endX),\(endY)) on \(deviceId)")],
            isError: false
        )

    default:
        return .init(
            content: [.text("Unknown tool: \(params.name)")],
            isError: true
        )
    }
}
```

## Defining Resources

Resources expose read-only data that AI agents can inspect.

```swift
func registerResourceHandlers(_ server: Server) async {
    // List available resources
    await server.withMethodHandler(ListResources.self) { params in
        let resources = [
            Resource(
                name: "Device List",
                uri: "device://list",
                description: "List of all available simulators, emulators, and connected devices",
                mimeType: "application/json"
            ),
            Resource(
                name: "Accessibility Tree",
                uri: "device://booted/accessibility-tree",
                description: "Current accessibility tree of the booted device's screen",
                mimeType: "application/json"
            ),
            Resource(
                name: "Device Info",
                uri: "device://booted/info",
                description: "Current device info (name, OS, screen size, state)",
                mimeType: "application/json"
            ),
            Resource(
                name: "Installed Apps",
                uri: "device://booted/apps",
                description: "List of apps installed on the booted device",
                mimeType: "application/json"
            ),
        ]
        return .init(resources: resources, nextCursor: nil)
    }

    // Read a resource
    await server.withMethodHandler(ReadResource.self) { params in
        switch params.uri {
        case "device://list":
            let devicesJSON = try await listDevices(platform: "all", state: "all")
            return .init(contents: [
                Resource.Content.text(devicesJSON, uri: params.uri, mimeType: "application/json")
            ])

        case "device://booted/accessibility-tree":
            let treeJSON = try await getAccessibilityTree(deviceId: "booted", platform: "ios")
            return .init(contents: [
                Resource.Content.text(treeJSON, uri: params.uri, mimeType: "application/json")
            ])

        case "device://booted/info":
            let infoJSON = try await getDeviceInfo(deviceId: "booted")
            return .init(contents: [
                Resource.Content.text(infoJSON, uri: params.uri, mimeType: "application/json")
            ])

        case "device://booted/apps":
            let appsJSON = try await getInstalledApps(deviceId: "booted")
            return .init(contents: [
                Resource.Content.text(appsJSON, uri: params.uri, mimeType: "application/json")
            ])

        default:
            throw MCPError.invalidParams("Unknown resource URI: \(params.uri)")
        }
    }

    // Handle resource subscriptions (for live updates)
    await server.withMethodHandler(ResourceSubscribe.self) { params in
        // Track subscription for live accessibility tree updates, etc.
        return .init()
    }
}
```

## Defining Prompts

Prompts provide templated workflows that AI agents can use.

```swift
func registerPromptHandlers(_ server: Server) async {
    await server.withMethodHandler(ListPrompts.self) { params in
        let prompts = [
            Prompt(
                name: "test-flow",
                description: "Guide an AI agent through testing a specific user flow in a mobile app",
                arguments: [
                    .init(name: "app_id", description: "Bundle ID or package name", required: true),
                    .init(name: "flow", description: "Description of the user flow to test", required: true),
                    .init(name: "platform", description: "ios or android", required: true),
                    .init(name: "device_id", description: "Device UDID or serial"),
                ]
            ),
            Prompt(
                name: "audit-app",
                description: "Audit a mobile app for accessibility, UX, and potential issues",
                arguments: [
                    .init(name: "app_id", description: "Bundle ID or package name", required: true),
                    .init(name: "platform", description: "ios or android", required: true),
                    .init(name: "focus", description: "Focus area: accessibility, ux, security, all"),
                ]
            ),
            Prompt(
                name: "explore-app",
                description: "Systematically explore an app's screens and document the UI structure",
                arguments: [
                    .init(name: "app_id", description: "Bundle ID or package name", required: true),
                    .init(name: "platform", description: "ios or android", required: true),
                ]
            ),
        ]
        return .init(prompts: prompts, nextCursor: nil)
    }

    await server.withMethodHandler(GetPrompt.self) { params in
        switch params.name {
        case "test-flow":
            let appId = params.arguments?["app_id"]?.stringValue ?? ""
            let flow = params.arguments?["flow"]?.stringValue ?? ""
            let platform = params.arguments?["platform"]?.stringValue ?? "ios"
            let deviceId = params.arguments?["device_id"]?.stringValue ?? "booted"

            return .init(
                description: "Test the '\(flow)' flow in \(appId)",
                messages: [
                    .user(.text(text: """
                        You are testing the mobile app \(appId) on \(platform) (device: \(deviceId)).

                        Test the following user flow: \(flow)

                        Instructions:
                        1. First, use `list_devices` to verify the device is available
                        2. Use `launch_app` to start the app
                        3. Use `get_accessibility_tree` to see the current screen
                        4. Use `take_screenshot` to capture the initial state
                        5. Plan and execute the test steps using `tap`, `type_text`, and `swipe`
                        6. After each action, use `get_accessibility_tree` to verify the result
                        7. Take screenshots at key checkpoints
                        8. Report: pass/fail for each step, any issues found, screenshots taken
                        """
                    )),
                ]
            )

        case "audit-app":
            let appId = params.arguments?["app_id"]?.stringValue ?? ""
            let platform = params.arguments?["platform"]?.stringValue ?? "ios"
            let focus = params.arguments?["focus"]?.stringValue ?? "all"

            return .init(
                description: "Audit \(appId) for \(focus)",
                messages: [
                    .user(.text(text: """
                        Audit the mobile app \(appId) on \(platform).
                        Focus: \(focus)

                        For each screen:
                        1. Launch the app and get the accessibility tree
                        2. Take a screenshot
                        3. Check for:
                           - Missing accessibility labels or identifiers
                           - Touch targets smaller than 44pt (iOS) or 48dp (Android)
                           - Contrast ratio issues (if visible in screenshot)
                           - Missing error states or loading indicators
                           - Navigation consistency
                        4. Navigate to the next screen and repeat
                        5. Compile a report with findings and recommendations
                        """
                    )),
                ]
            )

        case "explore-app":
            let appId = params.arguments?["app_id"]?.stringValue ?? ""
            let platform = params.arguments?["platform"]?.stringValue ?? "ios"

            return .init(
                description: "Explore \(appId) UI structure",
                messages: [
                    .user(.text(text: """
                        Systematically explore the mobile app \(appId) on \(platform).

                        For each screen:
                        1. Get the accessibility tree and take a screenshot
                        2. Document: screen name, elements, navigation options
                        3. Tap each navigable element to discover new screens
                        4. Map the complete navigation graph
                        5. Output a structured map of all discovered screens and transitions
                        """
                    )),
                ]
            )

        default:
            throw MCPError.invalidParams("Unknown prompt: \(params.name)")
        }
    }
}
```

## Content Types

MCP supports several content types in tool responses:

```swift
// Text content
.text("Operation completed successfully")

// Image content (base64 encoded)
.image(base64String, mimeType: "image/png")

// Audio content (base64 encoded)
.audio(base64String, mimeType: "audio/wav")

// Embedded resource
.resource(resource, uri: "device://booted/screenshot", mimeType: "image/png")

// Resource link (reference without embedding)
.resourceLink(uri: "device://booted/accessibility-tree", name: "Current Screen Tree")
```

## Error Handling

```swift
// In tool handlers, return errors as content with isError: true
return .init(
    content: [.text("Device not found: \(deviceId)")],
    isError: true
)

// For protocol-level errors, throw MCPError
throw MCPError.invalidParams("device_id is required")
throw MCPError.methodNotFound("Unknown tool: \(name)")
throw MCPError.internalError("Failed to connect to device")
```

## Server Logging

MCP servers can send log messages to the client:

```swift
// Send log notifications to the connected client
try await server.sendNotification(LoggingMessage.self) { params in
    // The client will receive these log messages
}

// Log levels: debug, info, warning, error, critical
```

## Claude Code Integration

### Configuration (claude_desktop_config.json or .claude/settings.local.json)

For stdio transport, configure as an MCP server:

```json
{
  "mcpServers": {
    "mobile-testing": {
      "command": "swift",
      "args": ["run", "--package-path", "/path/to/MobileTestingMCP", "MobileTestingMCP"],
      "env": {
        "ANDROID_HOME": "/Users/you/Library/Android/sdk"
      }
    }
  }
}
```

Or if built as a binary:

```json
{
  "mcpServers": {
    "mobile-testing": {
      "command": "/path/to/MobileTestingMCP",
      "env": {}
    }
  }
}
```

### For HTTP transport (remote server)

```json
{
  "mcpServers": {
    "mobile-testing": {
      "url": "http://localhost:8080",
      "transport": "http"
    }
  }
}
```

## Testing MCP Servers

### MCP Inspector

Use the official MCP Inspector to test your server interactively:

```bash
npx @modelcontextprotocol/inspector swift run --package-path /path/to/MobileTestingMCP MobileTestingMCP
```

The Inspector provides a web UI to:
- List and call tools
- List and read resources
- List and get prompts
- View server logs

### Programmatic testing

```swift
import Testing
import MCP

@Test func testListTools() async throws {
    let server = Server(
        name: "test",
        version: "1.0.0",
        capabilities: .init(tools: .init())
    )
    await registerToolHandlers(server)

    // Use in-memory transport for testing
    // Connect a test client and verify tool list
}
```

## Design Patterns for Mobile Testing MCP

### Tool naming conventions

Use snake_case, verb-first naming:
- `take_screenshot` not `screenshot`
- `get_accessibility_tree` not `accessibilityTree`
- `list_devices` not `devices`
- `launch_app` not `openApp`

### Input schema best practices

- Always include `device_id` and `platform` for device-specific tools
- Use enums for constrained values (`"enum": ["ios", "android"]`)
- Provide defaults for optional parameters
- Write clear descriptions — the AI agent reads these to understand the tool

### Resource URI design

Use a consistent URI scheme:
```
device://list                          — all devices
device://{device_id}/info              — device info
device://{device_id}/accessibility-tree — current screen tree
device://{device_id}/screenshot        — current screenshot
device://{device_id}/apps              — installed apps
device://{device_id}/logs              — recent logs
```

### Combining screenshot + accessibility tree

The most powerful pattern for AI-driven testing: return both a screenshot and the accessibility tree so the AI can see what the screen looks like AND know the exact element hierarchy with tappable coordinates.

```swift
case "inspect_screen":
    let screenshot = try await captureScreenshot(deviceId: deviceId, platform: platform, format: "png")
    let tree = try await getAccessibilityTree(deviceId: deviceId, platform: platform)

    return .init(
        content: [
            .image(screenshot.base64EncodedString(), mimeType: "image/png"),
            .text(tree)  // JSON accessibility tree
        ],
        isError: false
    )
```
