---
name: vapor
description: Guide for building server-side Swift APIs with Vapor — routing, controllers, Content protocol, middleware, error handling, WebSockets, HTTP client, and project structure.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-04 |
| Vapor | 4.x (4.121.3+), written for v5 forward-compatibility |
| Vapor 5 Status | Pre-alpha (alpha.1 milestone ~35% complete as of Mar 2026) |
| Swift | 6.0+ |
| Platforms | macOS, Linux (Ubuntu, Amazon Linux) |
| Docs | [docs.vapor.codes](https://docs.vapor.codes) |
| Source | [github.com/vapor/vapor](https://github.com/vapor/vapor) |

### Update checklist
- [ ] Check [Vapor releases](https://github.com/vapor/vapor/releases) for new versions
- [ ] Check [Vapor 5 milestones](https://github.com/vapor/vapor/milestones) for alpha/beta/release progress
- [ ] Check [Vapor docs](https://docs.vapor.codes) for API changes
- [ ] Review [Vapor blog](https://blog.vapor.codes) for announcements
- [ ] Check for macro routing (`@GET`, `@POST`, `@Controller`) availability
- [ ] Verify async/await patterns are current with latest Swift version
- [ ] Check if WebSocket/bcrypt/TLS traits need explicit opt-in

# Vapor Skill

Guide for building server-side Swift REST APIs with Vapor, covering routing, request/response handling, middleware, error handling, and project organization.

## When to use

Use this skill when:
- Building REST API endpoints for the mobile testing framework
- Creating HTTP server alongside or as alternative to gRPC
- Serving test results, reports, and screenshots via HTTP
- Building a web dashboard or webhook receiver
- Integrating HTTP client calls to external services (LLM APIs, CI/CD)

## Vapor 5 Migration Notes

Vapor 5 is in pre-alpha development. This skill uses **v4 APIs but follows patterns that will ease v5 migration**. Key upcoming changes:

### What's changing in v5

| Area | Vapor 4 (current) | Vapor 5 (upcoming) |
|------|-------------------|-------------------|
| Routing | Closure + `RouteCollection` | `@Controller` macro + `@GET`/`@POST` decorators |
| Route params | `req.parameters.get("id")!` | Injected as function args (type-safe) |
| HTTP methods | `.GET`, `.POST` (uppercase) | `.get`, `.post` (lowercase, from HTTPTypes) |
| RouteCollection | `func boot(routes:) throws` | `func boot(routes:) async throws` |
| Dependencies | All bundled | WebSocket, bcrypt, TLS behind package traits (opt-in) |
| Middleware | `@Controller` doesn't support yet | Macro-based middleware planned (`@Middleware`) |

### Macro routing preview (v5)

```swift
// Vapor 5 — @Controller macro auto-registers routes
@Controller
struct DeviceController {
    @GET("api", "v1", "devices")
    func list(req: Request) async throws -> [DeviceInfo] {
        try await listDevices()
    }

    @GET("api", "v1", "devices", String.self)
    func show(req: Request, deviceId: String) async throws -> DeviceInfo {
        try await getDeviceInfo(deviceId)
    }

    @POST("api", "v1", "devices", String.self, "tap")
    func tap(req: Request, deviceId: String) async throws -> ActionResponse {
        let body = try req.content.decode(TapBody.self)
        try await performTap(deviceId: deviceId, x: body.x, y: body.y)
        return ActionResponse(success: true, message: "Tapped", timestamp: Date())
    }
}
```

### Forward-compatibility guidelines

To minimize v5 migration effort:
1. **Always use `async throws`** on handler methods (already required in latest v4)
2. **Use `AsyncMiddleware`** not `Middleware` (v5 drops sync middleware)
3. **Use `RouteCollection`** pattern — easy to convert to `@Controller` later
4. **Avoid EventLoopFuture** — use async/await exclusively
5. **Keep route handlers as plain methods** on structs (maps directly to `@Controller`)
6. **Don't force-unwrap parameters** — use `guard let` with typed casting
7. **Use `Content` protocol** for all request/response types (unchanged in v5)

## Project Setup

### Create new project

```bash
# Using Vapor toolbox
brew install vapor
vapor new MyServer -n
cd MyServer

# Or manually with SPM
mkdir MyServer && cd MyServer
swift package init --type executable --name MyServer
```

### Package.swift

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmooServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.121.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)
```

### Entry point

```swift
// Sources/App/entrypoint.swift
import Vapor

@main
struct App {
    static func main() async throws {
        let app = try await Application.make()
        try configure(app)
        try await app.execute()
    }
}
```

### Configuration

```swift
// Sources/App/configure.swift
import Vapor

func configure(_ app: Application) throws {
    // Middleware
    app.middleware.use(CORSMiddleware(configuration: .default()), at: .beginning)

    // Routes
    try routes(app)
}
```

### Routes

```swift
// Sources/App/routes.swift
import Vapor

func routes(_ app: Application) throws {
    app.get { req in
        "Mobile Testing Server is running"
    }

    // Register controllers
    try app.register(collection: DeviceController())
    try app.register(collection: ScreenshotController())
    try app.register(collection: TestController())
}
```

## Routing

### Basic routes

```swift
// GET /hello
app.get("hello") { req -> String in
    "Hello, world!"
}

// POST /users
app.post("users") { req -> HTTPStatus in
    let user = try req.content.decode(CreateUserRequest.self)
    // ... create user
    return .created
}

// PUT /users/:id
app.put("users", ":id") { req -> User in
    guard let id = req.parameters.get("id", as: UUID.self) else {
        throw Abort(.badRequest, reason: "Invalid user ID")
    }
    let update = try req.content.decode(UpdateUserRequest.self)
    // ... update user
    return updatedUser
}

// DELETE /users/:id
app.delete("users", ":id") { req -> HTTPStatus in
    guard let id = req.parameters.get("id", as: UUID.self) else {
        throw Abort(.badRequest, reason: "Invalid user ID")
    }
    // ... delete user
    return .noContent
}
```

### Path parameters

```swift
// Single parameter
app.get("devices", ":deviceId") { req -> DeviceInfo in
    let deviceId = req.parameters.get("deviceId")!
    return try await getDeviceInfo(deviceId)
}

// Multiple parameters
app.get("devices", ":deviceId", "apps", ":appId") { req -> AppInfo in
    let deviceId = req.parameters.get("deviceId")!
    let appId = req.parameters.get("appId")!
    return try await getAppInfo(deviceId: deviceId, appId: appId)
}

// Typed parameters
app.get("tests", ":id") { req -> TestResult in
    guard let id = req.parameters.get("id", as: Int.self) else {
        throw Abort(.badRequest)
    }
    return try await getTestResult(id)
}

// Catchall (matches remaining path segments)
app.get("files", "**") { req -> Response in
    let path = req.parameters.getCatchall().joined(separator: "/")
    // serve file at path
}
```

### Query parameters

```swift
// GET /devices?platform=ios&state=booted
app.get("devices") { req -> [DeviceInfo] in
    // Decode query string into struct
    let filter = try req.query.decode(DeviceFilter.self)
    return try await listDevices(filter: filter)
}

struct DeviceFilter: Content {
    var platform: String?
    var state: String?
}

// Single query parameter
app.get("search") { req -> [SearchResult] in
    guard let query: String = req.query["q"] else {
        throw Abort(.badRequest, reason: "Missing query parameter 'q'")
    }
    return try await search(query)
}
```

## Content Protocol (Request/Response Bodies)

### Define models

```swift
// Models that can be encoded to/decoded from HTTP bodies
struct DeviceInfo: Content {
    let id: String
    let name: String
    let platform: String
    let osVersion: String
    let state: String
}

struct TapRequest: Content {
    let deviceId: String
    let x: Int
    let y: Int
}

struct ActionResponse: Content {
    let success: Bool
    let message: String
    let timestamp: Date
}

struct ScreenshotResponse: Content {
    let deviceId: String
    let format: String
    let width: Int
    let height: Int
    let data: String  // base64
}
```

### Request decoding

```swift
// JSON body decoding (automatic from Content-Type header)
app.post("actions", "tap") { req -> ActionResponse in
    let tapRequest = try req.content.decode(TapRequest.self)
    try await performTap(
        deviceId: tapRequest.deviceId,
        x: tapRequest.x,
        y: tapRequest.y
    )
    return ActionResponse(
        success: true,
        message: "Tapped at (\(tapRequest.x), \(tapRequest.y))",
        timestamp: Date()
    )
}
```

### Response encoding

```swift
// Return Content-conforming types directly (auto-encodes to JSON)
app.get("devices", ":id") { req -> DeviceInfo in
    let deviceId = req.parameters.get("id")!
    return try await getDeviceInfo(deviceId)
}

// Custom response with status code and headers
app.post("screenshots") { req -> Response in
    let request = try req.content.decode(ScreenshotRequest.self)
    let imageData = try await captureScreenshot(request)

    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "image/png")
    headers.add(name: .contentDisposition, value: "inline; filename=\"screenshot.png\"")

    return Response(
        status: .ok,
        headers: headers,
        body: .init(data: imageData)
    )
}

// Return different status codes
app.post("devices") { req -> Response in
    let request = try req.content.decode(CreateDeviceRequest.self)
    let device = try await createDevice(request)
    let response = Response(status: .created)
    try response.content.encode(device)
    return response
}
```

### Validation hooks

```swift
struct CreateTestRequest: Content {
    var name: String
    var appId: String
    var steps: [TestStep]

    // Called after decoding — sanitize/validate
    mutating func afterDecode() throws {
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Test name cannot be empty")
        }
        guard !steps.isEmpty else {
            throw Abort(.badRequest, reason: "Test must have at least one step")
        }
    }
}
```

## Controllers

### RouteCollection pattern

```swift
// Note: In Vapor 5, boot() becomes async: `func boot(routes:) async throws`
// Using `throws` here is forward-compatible — just add `async` when upgrading
struct DeviceController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let devices = routes.grouped("api", "v1", "devices")

        devices.get(use: list)
        devices.post(use: create)

        devices.group(":deviceId") { device in
            device.get(use: show)
            device.delete(use: shutdown)
            device.post("screenshot", use: screenshot)
            device.post("tap", use: tap)
            device.post("type", use: typeText)
            device.post("swipe", use: swipe)
            device.get("accessibility-tree", use: accessibilityTree)
            device.get("apps", use: installedApps)
        }
    }

    // GET /api/v1/devices
    func list(req: Request) async throws -> [DeviceInfo] {
        let filter = try? req.query.decode(DeviceFilter.self)
        return try await listDevices(filter: filter)
    }

    // GET /api/v1/devices/:deviceId
    func show(req: Request) async throws -> DeviceInfo {
        let deviceId = req.parameters.get("deviceId")!
        return try await getDeviceInfo(deviceId)
    }

    // POST /api/v1/devices/:deviceId/screenshot
    func screenshot(req: Request) async throws -> Response {
        let deviceId = req.parameters.get("deviceId")!
        let imageData = try await captureScreenshot(deviceId: deviceId)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "image/png")
        return Response(status: .ok, headers: headers, body: .init(data: imageData))
    }

    // POST /api/v1/devices/:deviceId/tap
    func tap(req: Request) async throws -> ActionResponse {
        let deviceId = req.parameters.get("deviceId")!
        let body = try req.content.decode(TapBody.self)
        try await performTap(deviceId: deviceId, x: body.x, y: body.y)
        return ActionResponse(success: true, message: "Tapped", timestamp: Date())
    }

    // GET /api/v1/devices/:deviceId/accessibility-tree
    func accessibilityTree(req: Request) async throws -> AccessibilityTree {
        let deviceId = req.parameters.get("deviceId")!
        return try await getAccessibilityTree(deviceId: deviceId)
    }
}

struct TapBody: Content {
    let x: Int
    let y: Int
}
```

### Register controllers

```swift
func routes(_ app: Application) throws {
    try app.register(collection: DeviceController())
    try app.register(collection: TestRunController())
    try app.register(collection: AuditController())
}
```

## Middleware

### Custom middleware

```swift
struct RequestLoggingMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let start = Date()
        request.logger.info("\(request.method) \(request.url.path)")

        let response = try await next.respond(to: request)

        let elapsed = Date().timeIntervalSince(start)
        request.logger.info("\(request.method) \(request.url.path) → \(response.status.code) (\(String(format: "%.2f", elapsed * 1000))ms)")

        return response
    }
}
```

### API key authentication middleware

```swift
struct APIKeyMiddleware: AsyncMiddleware {
    let validKeys: Set<String>

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let apiKey = request.headers.first(name: "X-API-Key"),
              validKeys.contains(apiKey) else {
            throw Abort(.unauthorized, reason: "Invalid or missing API key")
        }
        return try await next.respond(to: request)
    }
}
```

### CORS configuration

```swift
let cors = CORSMiddleware(configuration: .init(
    allowedOrigin: .all,
    allowedMethods: [.GET, .POST, .PUT, .DELETE, .PATCH, .OPTIONS],
    allowedHeaders: [
        .accept, .authorization, .contentType, .origin,
        .init("X-API-Key")
    ]
))
app.middleware.use(cors, at: .beginning)
```

### Applying middleware

```swift
// Global
app.middleware.use(RequestLoggingMiddleware())

// Route group
let protected = app.grouped(APIKeyMiddleware(validKeys: ["secret-key"]))
protected.get("admin", "status") { req in "OK" }

// Combined
let api = app.grouped("api", "v1")
    .grouped(APIKeyMiddleware(validKeys: ["key1"]))
    .grouped(RequestLoggingMiddleware())
```

## Error Handling

### Abort (built-in)

```swift
// Simple abort with HTTP status
throw Abort(.notFound)
throw Abort(.badRequest, reason: "Missing required field 'deviceId'")
throw Abort(.unauthorized, reason: "Invalid credentials")
throw Abort(.internalServerError, reason: "Failed to connect to device")
```

### Custom error types

```swift
enum DeviceError: AbortError {
    case notFound(String)
    case notBooted(String)
    case commandFailed(String)
    case timeout(String)

    var status: HTTPResponseStatus {
        switch self {
        case .notFound: return .notFound
        case .notBooted: return .conflict
        case .commandFailed: return .internalServerError
        case .timeout: return .gatewayTimeout
        }
    }

    var reason: String {
        switch self {
        case .notFound(let id): return "Device not found: \(id)"
        case .notBooted(let id): return "Device not booted: \(id). Boot it first."
        case .commandFailed(let msg): return "Command failed: \(msg)"
        case .timeout(let op): return "Operation timed out: \(op)"
        }
    }
}

// Usage
throw DeviceError.notFound("ABC-123")
```

### Error response format

Vapor's default `ErrorMiddleware` returns JSON errors:

```json
{
    "error": true,
    "reason": "Device not found: ABC-123"
}
```

## WebSocket Support

> **Vapor 5 note:** WebSocket support moves behind a package trait. You'll need to
> explicitly enable it: `swift build --traits WebSockets` or keep using the default
> traits (enabled by default initially). Plan for this dependency to be optional.

Useful for streaming test results or live device logs:

```swift
app.webSocket("ws", "logs", ":deviceId") { req, ws in
    let deviceId = req.parameters.get("deviceId")!

    ws.onText { ws, text in
        // Receive filter commands from client
        req.logger.info("Log filter: \(text)")
    }

    // Stream logs to WebSocket
    Task {
        for await logLine in streamDeviceLogs(deviceId: deviceId) {
            try await ws.send(logLine)
        }
    }

    ws.onClose.whenComplete { _ in
        req.logger.info("WebSocket closed for device \(deviceId)")
    }
}
```

## HTTP Client (Outgoing Requests)

For calling external APIs (LLMs, CI/CD, etc.):

```swift
// In a route handler — use req.client
app.post("ai", "generate-tests") { req -> GeneratedTests in
    let body = try req.content.decode(GenerateTestsRequest.self)

    // Call Ollama or other LLM API
    let response = try await req.client.post("http://localhost:11434/api/generate") { outReq in
        try outReq.content.encode([
            "model": "llama3",
            "prompt": "Generate test cases for: \(body.description)",
        ])
    }

    let llmResponse = try response.content.decode(OllamaResponse.self)
    return GeneratedTests(tests: parseLLMOutput(llmResponse.response))
}
```

## Project Structure

```
AmooServer/
├── Package.swift
├── Sources/
│   └── App/
│       ├── entrypoint.swift         # @main entry point
│       ├── configure.swift          # App configuration
│       ├── routes.swift             # Route registration
│       ├── Controllers/
│       │   ├── DeviceController.swift
│       │   ├── TestRunController.swift
│       │   └── AuditController.swift
│       ├── Models/
│       │   ├── DeviceInfo.swift
│       │   ├── TestResult.swift
│       │   └── ActionRequest.swift
│       ├── Middleware/
│       │   ├── APIKeyMiddleware.swift
│       │   └── RequestLoggingMiddleware.swift
│       └── Services/
│           ├── IOSDriverService.swift
│           ├── AndroidDriverService.swift
│           └── LLMService.swift
└── Tests/
    └── AppTests/
        ├── DeviceControllerTests.swift
        └── TestRunControllerTests.swift
```

## Testing

```swift
import VaporTesting
import Testing

@testable import App

// Note: In Vapor 5, HTTP method constants change to lowercase (.get, .post)
// Use lowercase now if your Vapor version supports it
@Test func testListDevices() async throws {
    try await withApp { app in
        try configure(app)

        try await app.testing().test(.GET, "api/v1/devices") { res in
            #expect(res.status == .ok)
            let devices = try res.content.decode([DeviceInfo].self)
            #expect(!devices.isEmpty)
        }
    }
}

@Test func testTapAction() async throws {
    try await withApp { app in
        try configure(app)

        try await app.testing().test(.POST, "api/v1/devices/booted/tap",
            beforeRequest: { req in
                try req.content.encode(TapBody(x: 100, y: 200))
            }
        ) { res in
            #expect(res.status == .ok)
            let response = try res.content.decode(ActionResponse.self)
            #expect(response.success)
        }
    }
}
```

## Build & Run

```bash
# Development
swift run App

# Release build
swift build -c release
.build/release/App

# With environment variables
VAPOR_PORT=8080 swift run App

# Custom hostname and port
swift run App --hostname 0.0.0.0 --port 8080
```

## API Design for Mobile Testing

### Recommended REST endpoints

```
GET    /api/v1/devices                        List all devices
POST   /api/v1/devices                        Create/boot a device
GET    /api/v1/devices/:id                    Get device info
DELETE /api/v1/devices/:id                    Shutdown device

POST   /api/v1/devices/:id/screenshot         Take screenshot
GET    /api/v1/devices/:id/accessibility-tree  Get accessibility tree
POST   /api/v1/devices/:id/actions/tap         Tap at coordinates
POST   /api/v1/devices/:id/actions/swipe       Swipe gesture
POST   /api/v1/devices/:id/actions/type        Type text
POST   /api/v1/devices/:id/actions/keypress    Send key event

POST   /api/v1/devices/:id/apps/install        Install app
POST   /api/v1/devices/:id/apps/:appId/launch  Launch app
DELETE /api/v1/devices/:id/apps/:appId         Uninstall app
GET    /api/v1/devices/:id/apps                List installed apps

POST   /api/v1/tests                           Start a test run
GET    /api/v1/tests/:id                       Get test results
GET    /api/v1/tests/:id/report                Get test report

WS     /ws/devices/:id/logs                    Stream device logs
WS     /ws/tests/:id/progress                  Stream test progress
```
